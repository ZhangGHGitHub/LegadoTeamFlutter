import 'dart:io' show File;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/bottom_bar_skin_service.dart';
/// [UI_SYNC_REFACTOR S1c] 主框架导航组件族（对齐参考仓 ShortNavigationBar/
/// AppNavigationBar/FloatingBottomBar/Rail）
///
/// 三态统一消费底栏皮肤图标：标准栏/悬浮胶囊/Rail 全部走 [SkinNavIcon]；
/// Rail 头部对齐参考：搜索钮（折叠态 ExpandedFAB 等效）+ 书架分组菜单
///（参考为 Rail 项长按菜单，本地交互等效为入口钮，登记差异）+ 展开切换
///（railExtended 持久化）。

/// 导航项规格（图标/文案/皮肤槽位）
class AppNavSpec {
  final IconData symbol;
  final String label;
  final String? skinSlot;

  const AppNavSpec({
    required this.symbol,
    required this.label,
    this.skinSlot,
  });
}

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
    Widget fallback() => Icon(spec.symbol, size: 24, fill: selected ? 1 : 0);
    if (spec.skinSlot == null || activeSkin.isEmpty) return fallback();
    return SkinNavIcon(
      skin: activeSkin,
      slot: spec.skinSlot!,
      selected: selected,
      fallback: fallback(),
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

  const AppFloatingBottomBar({
    super.key,
    required this.specs,
    required this.currentIndex,
    required this.activeSkin,
    required this.onSelect,
    required this.useBlur,
    required this.blurRadius,
    required this.blurAlpha,
  });

  @override
  State<AppFloatingBottomBar> createState() => _AppFloatingBottomBarState();
}

class _AppFloatingBottomBarState extends State<AppFloatingBottomBar> {
  int _pressedIndex = -1;

  Widget _icon(int index, {required bool selected}) {
    final spec = widget.specs[index];
    Widget fallback({required bool sel}) =>
        Icon(spec.symbol, size: 24, fill: sel ? 1 : 0);
    if (widget.activeSkin.isEmpty || spec.skinSlot == null) {
      return fallback(sel: selected);
    }
    return SkinNavIcon(
      skin: widget.activeSkin,
      slot: spec.skinSlot!,
      selected: selected,
      fallback: fallback(sel: selected),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.fastOutSlowIn,
                      width: widget.currentIndex == i ? 64 : 48,
                      height: 32,
                      decoration: BoxDecoration(
                        color: widget.currentIndex == i
                            ? cs.secondaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: AnimatedScale(
                        scale: widget.currentIndex == i ? 1.2 : 1.0,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.fastOutSlowIn,
                        child: _icon(i, selected: widget.currentIndex == i),
                      ),
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
    this.groups,
    this.selectedGroupIndex,
    this.onGroupSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget railIcon(AppNavSpec spec, {required bool selected}) {
      Widget fallback() => Icon(spec.symbol, size: 24, fill: selected ? 1 : 0);
      if (spec.skinSlot == null || activeSkin.isEmpty) return fallback();
      return SkinNavIcon(
        skin: activeSkin,
        slot: spec.skinSlot!,
        selected: selected,
        fallback: fallback(),
      );
    }

    return NavigationRail(
      selectedIndex: currentIndex,
      onDestinationSelected: onSelect,
      // 展开态走 extended 侧栏形态；折叠态仅选中显示 label
      extended: extended,
      labelType: extended
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      leading: Column(
        children: [
          const SizedBox(height: 8),
          // 展开切换（railExtended 持久化）
          IconButton(
            tooltip: extended ? '收起侧栏' : '展开侧栏',
            icon: Icon(extended
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
