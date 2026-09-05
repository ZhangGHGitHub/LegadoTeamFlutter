import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_strings.dart';
import '../providers/bottom_bar_skin_notifier.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/theme/system_bar_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../services/bottom_bar_skin_service.dart';
import 'bookshelf_screen.dart';
import 'explore_screen.dart';
import 'rss_screen.dart';
import 'settings_screen.dart';

/// 首页 - 底部 Tab 导航 + 左右滑动切页
///
/// 对齐安卓原版 MainActivity（activity_main.xml）：
/// - ViewPager（左右滑动切页）与 BottomNavigationView（图标底栏）并存
/// - 双击底栏项（300ms 内）：书架页回滚顶部 / 发现页收起展开项
///   （对标 onNavigationItemReselected → gotoTop/compressExplore）
/// - 返回键两段式：非书架页先回书架页；书架页 2 秒内二次返回退出
///   （对标 onBackPressedDispatcher + double_click_exit）
/// - [UI-fix v2.0.5 | 2026-08-08] 接通其他设置页主界面分组：显示发现/
///   显示订阅控制 Tab 显隐、默认首页控制启动落地页
///   （对标原版 AppConfig.showDiscovery/showRSS/defaultHomePage） — Qoder
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

/// 首页逻辑 Tab（与底栏索引解耦，便于按偏好动态显隐）
enum _HomeTab { bookshelf, explore, rss, my }

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// 底栏双击判定窗口（对标原版 bookshelfReselected/exploreReselected 300ms）
  static const _reselectInterval = Duration(milliseconds: 300);

  /// 返回键双击退出判定窗口（对标原版 EXIT_INTERVAL = 2000ms）
  static const _exitInterval = Duration(seconds: 2);

  /// [LAYOUT_MOTION_AUDIT L3] IndexedStack 当前索引。
  /// 禁滑动切页（HapeLee IndexedStack 语义），切页一律经 setState 切索引。
  int _stackIndex = 0;

  /// 当前逻辑 Tab（Tab 显隐变化时据此重新定位索引）
  _HomeTab _currentTab = _HomeTab.bookshelf;

  /// 已访问过的 Tab 集合（首屏默认访问书架）— 保留懒构建语义
  final Set<_HomeTab> _visitedTabs = {_HomeTab.bookshelf};

  /// 书架页回滚顶部信号（双击书架底栏项时自增）
  final ValueNotifier<int> _bookshelfScrollTopSignal = ValueNotifier(0);

  /// 发现页收起展开项信号（双击发现底栏项时自增）
  final ValueNotifier<int> _exploreCollapseSignal = ValueNotifier(0);

  DateTime? _lastTapTime;
  int _lastTapIndex = -1;
  DateTime? _lastBackTime;

  /// 默认首页是否已应用（偏好异步加载完成后仅跳转一次）
  bool _defaultHomePageApplied = false;

  @override
  void dispose() {
    _bookshelfScrollTopSignal.dispose();
    _exploreCollapseSignal.dispose();
    super.dispose();
  }

  /// 按主界面偏好计算可见 Tab 列表（对标原版 showDiscovery/showRSS 显隐）
  List<_HomeTab> _visibleTabs(MainPrefsState prefs) => [
        _HomeTab.bookshelf,
        if (prefs.showDiscovery) _HomeTab.explore,
        if (prefs.showRss) _HomeTab.rss,
        _HomeTab.my,
      ];

  /// 默认首页偏好值 → 逻辑 Tab（对标原版 defaultHomePage 数组值）
  _HomeTab _tabOfHomePage(String value) {
    switch (value) {
      case 'explore':
        return _HomeTab.explore;
      case 'rss':
        return _HomeTab.rss;
      case 'my':
        return _HomeTab.my;
      default:
        return _HomeTab.bookshelf;
    }
  }

  void _onDestinationSelected(List<_HomeTab> tabs, int index) {
    final now = DateTime.now();
    final currentIndex = tabs.indexOf(_currentTab);
    // 双击检测：300ms 内再次点击当前选中项 → 触发 reselect 动作
    if (index == currentIndex &&
        _lastTapIndex == index &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!) <= _reselectInterval) {
      _lastTapTime = null;
      _onReselect(tabs[index]);
      return;
    }
    _lastTapTime = now;
    _lastTapIndex = index;
    if (index != currentIndex) {
      // 对标原版 setCurrentItem(position, false)：无过渡动画
      // [LAYOUT_MOTION_AUDIT L3] IndexedStack 直接切索引（禁滑动切页）
      setState(() => _stackIndex = index);
      _onPageChanged(tabs, index);
    }
  }

  /// 底栏双击动作（对标 onNavigationItemReselected）
  void _onReselect(_HomeTab tab) {
    switch (tab) {
      case _HomeTab.bookshelf: // 书架：gotoTop
        _bookshelfScrollTopSignal.value++;
      case _HomeTab.explore: // 发现：compressExplore（收起已展开的分类）
        _exploreCollapseSignal.value++;
      default:
        break;
    }
  }

  void _onPageChanged(List<_HomeTab> tabs, int index) {
    setState(() {
      _currentTab = tabs[index];
      _visitedTabs.add(_currentTab);
    });
  }

  /// 返回键两段式处理（对标 MainActivity.onBackPressedDispatcher）
  Future<void> _handleBack(List<_HomeTab> tabs) async {
    if (_currentTab != _HomeTab.bookshelf) {
      // [LAYOUT_MOTION_AUDIT L3] IndexedStack 回书架
      final index = tabs.indexOf(_HomeTab.bookshelf);
      setState(() => _stackIndex = index >= 0 ? index : 0);
      _onPageChanged(tabs, _stackIndex);
      return;
    }
    final now = DateTime.now();
    if (_lastBackTime != null &&
        now.difference(_lastBackTime!) <= _exitInterval) {
      await SystemNavigator.pop();
      return;
    }
    _lastBackTime = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppStrings.doubleClickExit),
          duration: _exitInterval,
        ),
      );
  }

  /// 构建底栏项（皮肤图优先；无皮肤时用 Material Symbols 默认 glyph，
  /// 选中态 FILL=1——UI_MD3_PLAN.md Batch 1）
  NavigationDestination _destination(
    BuildContext context,
    IconData symbol,
    String label, {
    String? skinSlot,
    String activeSkin = '',
  }) {
    Widget fallbackIcon({required bool selected}) {
      return Icon(symbol, size: 24, fill: selected ? 1 : 0);
    }

    if (activeSkin.isEmpty || skinSlot == null) {
      return NavigationDestination(
        icon: fallbackIcon(selected: false),
        selectedIcon: fallbackIcon(selected: true),
        label: label,
      );
    }

    return NavigationDestination(
      icon: _SkinIcon(
        skin: activeSkin,
        slot: skinSlot,
        selected: false,
        fallback: fallbackIcon(selected: false),
      ),
      selectedIcon: _SkinIcon(
        skin: activeSkin,
        slot: skinSlot,
        selected: true,
        fallback: fallbackIcon(selected: true),
      ),
      label: label,
    );
  }

  /// 逻辑 Tab → 页面内容（未访问过的 Tab 用占位以保留懒构建语义）
  Widget _pageOf(_HomeTab tab) {
    switch (tab) {
      case _HomeTab.bookshelf:
        return BookshelfScreen(scrollTopSignal: _bookshelfScrollTopSignal);
      case _HomeTab.explore:
        return _visitedTabs.contains(tab)
            ? ExploreScreen(collapseSignal: _exploreCollapseSignal)
            : const SizedBox.shrink();
      case _HomeTab.rss:
        return _visitedTabs.contains(tab)
            ? const RssScreen()
            : const SizedBox.shrink();
      case _HomeTab.my:
        return _visitedTabs.contains(tab)
            ? const SettingsScreen()
            : const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(mainPrefsProvider);
    final skinState = ref.watch(bottomBarSkinProvider);
    final activeSkin = skinState.active;
    final tabs = _visibleTabs(prefs);
    // 偏好加载完成后应用默认首页（仅启动时生效一次，对标原版
    // ViewPager 初始 setCurrentItem(defaultHomePage)）
    ref.listen(mainPrefsProvider, (previous, next) {
      if (_defaultHomePageApplied) return;
      final target = _tabOfHomePage(next.defaultHomePage);
      if (target == _HomeTab.bookshelf) {
        _defaultHomePageApplied = true;
        return;
      }
      final targetIndex = _visibleTabs(next).indexOf(target);
      // 目标 Tab 被隐藏或用户已手动切页时不再跳转
      if (targetIndex >= 0 && _currentTab == _HomeTab.bookshelf) {
        _defaultHomePageApplied = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // [LAYOUT_MOTION_AUDIT L3] IndexedStack 直接切索引
          setState(() => _stackIndex = targetIndex);
          _onPageChanged(_visibleTabs(next), targetIndex);
        });
      }
    });
    // Tab 显隐变化后当前 Tab 可能被隐藏，回退书架并同步页面位置
    var currentIndex = tabs.indexOf(_currentTab);
    if (currentIndex < 0) {
      _currentTab = _HomeTab.bookshelf;
      currentIndex = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // [LAYOUT_MOTION_AUDIT L3] IndexedStack 直接切索引
        setState(() => _stackIndex = 0);
      });
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack(tabs);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ui = ref.watch(uiSettingsProvider);
          final useRail = _railActive(
            ui,
            constraints.maxWidth,
            MediaQuery.of(context).orientation,
          );
          final pageArea = IndexedStack(
            index: currentIndex,
            children: [for (final tab in tabs) _pageOf(tab)],
          );
          return Scaffold(
            // 沉浸式状态栏开启时顶栏延伸至状态栏区域（对标原版 fullScreen +
            // AppConfig.isTransparentStatusBar）；关闭时保留顶部 SafeArea
            body: SafeArea(
              top: !ref.watch(
                systemBarProvider.select((s) => s.transparentStatusBar),
              ),
              bottom: false,
              // [UI_SYNC_REFACTOR B3] tabletInterface + sw≥600 切 NavigationRail
              //（简版：系统图标不带皮肤，expand 持久化登记差异延后）
              child: useRail
                  ? Row(
                      children: [
                        _buildRail(ui, tabs, currentIndex),
                        const VerticalDivider(width: 1, thickness: 0),
                        Expanded(child: pageArea),
                      ],
                    )
                  : pageArea,
            ),
            // [UI_SYNC_REFACTOR B3] 底栏三形态：隐藏 / 悬浮 64dp 胶囊 / 标准
            // NavigationBar（label 三档 + 透明度）；皮肤图标两种形态均保留
            bottomNavigationBar: _buildBottomBar(
              context,
              ui,
              tabs,
              currentIndex,
              activeSkin,
            ),
          );
        },
      ),
    );
  }

  /// Rail 激活判定（对齐参考仓 tabletInterface：auto/always/landscape/off）
  bool _railActive(UiSettingsState ui, double width, Orientation orientation) {
    switch (ui.tabletInterface) {
      case TabletInterfaceMode.always:
        return true;
      case TabletInterfaceMode.landscape:
        return orientation == Orientation.landscape;
      case TabletInterfaceMode.off:
        return false;
      case TabletInterfaceMode.auto:
        return width >= 600;
    }
  }

  /// 平板 Rail（简版：系统图标；皮肤图标消费留在标准/悬浮底栏）
  Widget _buildRail(UiSettingsState ui, List<_HomeTab> tabs, int currentIndex) {
    Widget railIcon(IconData symbol, {required bool selected}) {
      return Icon(symbol, size: 24, fill: selected ? 1 : 0);
    }

    return NavigationRail(
      selectedIndex: currentIndex,
      onDestinationSelected: (index) =>
          _onDestinationSelected(tabs, index),
      labelType: NavigationRailLabelType.all,
      leading: const SizedBox(height: 8),
      destinations: [
        for (final tab in tabs)
          switch (tab) {
            _HomeTab.bookshelf => NavigationRailDestination(
                icon: railIcon(Symbols.menu_book_rounded, selected: false),
                selectedIcon: railIcon(Symbols.menu_book_rounded, selected: true),
                label: Text(AppStrings.bookshelf),
              ),
            _HomeTab.explore => NavigationRailDestination(
                icon: railIcon(Symbols.explore_rounded, selected: false),
                selectedIcon:
                    railIcon(Symbols.explore_rounded, selected: true),
                label: Text(AppStrings.discover),
              ),
            _HomeTab.rss => NavigationRailDestination(
                icon: railIcon(Symbols.feed_rounded, selected: false),
                selectedIcon: railIcon(Symbols.feed_rounded, selected: true),
                label: Text(AppStrings.rss),
              ),
            _HomeTab.my => NavigationRailDestination(
                icon: railIcon(Symbols.person_rounded, selected: false),
                selectedIcon: railIcon(Symbols.person_rounded, selected: true),
                label: Text(AppStrings.my),
              ),
          },
      ],
    );
  }

  /// 底栏构建：隐藏 / 悬浮胶囊 / 标准 NavigationBar（label 三档+透明度）
  Widget? _buildBottomBar(
    BuildContext context,
    UiSettingsState ui,
    List<_HomeTab> tabs,
    int currentIndex,
    String activeSkin,
  ) {
    if (!ui.showBottomView) return null;
    if (ui.useFloatingBottomBar) {
      return _FloatingBottomBar(
        specs: [
          for (final tab in tabs)
            switch (tab) {
              _HomeTab.bookshelf => (
                  symbol: Symbols.menu_book_rounded,
                  label: AppStrings.bookshelf,
                  skinSlot: 'bookshelf',
                ),
              _HomeTab.explore => (
                  symbol: Symbols.explore_rounded,
                  label: AppStrings.discover,
                  skinSlot: 'home',
                ),
              _HomeTab.rss => (
                  symbol: Symbols.feed_rounded,
                  label: AppStrings.rss,
                  skinSlot: 'notes',
                ),
              _HomeTab.my => (
                  symbol: Symbols.person_rounded,
                  label: AppStrings.my,
                  skinSlot: 'settings',
                ),
            },
        ],
        currentIndex: currentIndex,
        activeSkin: activeSkin,
        onSelect: (index) => _onDestinationSelected(tabs, index),
      );
    }
    return Opacity(
      opacity: ui.bottomBarOpacity / 100,
      child: NavigationBar(
        // [UI_SYNC_REFACTOR B3] label 三档（auto=仅选中/labeled=常显/unlabeled=纯图标）
        labelBehavior: switch (ui.labelVisibilityMode) {
          BottomBarLabelMode.auto =>
            NavigationDestinationLabelBehavior.onlyShowSelected,
          BottomBarLabelMode.labeled =>
            NavigationDestinationLabelBehavior.alwaysShow,
          BottomBarLabelMode.unlabeled =>
            NavigationDestinationLabelBehavior.alwaysHide,
        },
        selectedIndex: currentIndex,
        onDestinationSelected: (index) => _onDestinationSelected(tabs, index),
        destinations: [
          for (final tab in tabs)
            switch (tab) {
              _HomeTab.bookshelf => _destination(
                  context,
                  Symbols.menu_book_rounded,
                  AppStrings.bookshelf,
                  skinSlot: 'bookshelf',
                  activeSkin: activeSkin,
                ),
              _HomeTab.explore => _destination(
                  context,
                  Symbols.explore_rounded,
                  AppStrings.discover,
                  skinSlot: 'home',
                  activeSkin: activeSkin,
                ),
              _HomeTab.rss => _destination(
                  context,
                  Symbols.feed_rounded,
                  AppStrings.rss,
                  skinSlot: 'notes',
                  activeSkin: activeSkin,
                ),
              _HomeTab.my => _destination(
                  context,
                  Symbols.person_rounded,
                  AppStrings.my,
                  skinSlot: 'settings',
                  activeSkin: activeSkin,
                ),
            },
        ],
      ),
    );
  }
}

/// 底栏皮肤图标（缺图回退系统 SVG）
class _SkinIcon extends StatelessWidget {
  const _SkinIcon({
    required this.skin,
    required this.slot,
    required this.selected,
    required this.fallback,
  });

  final String skin;
  final String slot;
  final bool selected;
  final Widget fallback;

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
          File(path),
          width: 24,
          height: 24,
          fit: BoxFit.contain,
          errorBuilder: (_, error, stack) => fallback,
        );
        if (selected || icons?.normal != null) return child;
        // 无 normal 时对 selected 图降透明（对齐原版 alpha=102）
        return Opacity(opacity: 0.4, child: child);
      },
    );
  }
}

/// [UI_SYNC_REFACTOR B3] 悬浮底栏（对齐参考仓 FloatingBottomBar，实色版）
///
/// 64dp 高 Stadium 胶囊、内边距 4dp、水平 margin 16dp + 底部 12dp+safeArea；
/// 底色 surfaceContainerHighest α0.85（enableBlur 接通后可切 BackdropFilter）；
/// 按压 scale 反馈（≈lerp(1, 1+16/width)）+ 图标 1→1.2；选中项 64×32 r16
/// 胶囊（secondaryContainer），对齐参考仓自定义图标选中胶囊。
class _FloatingBottomBar extends StatefulWidget {
  final List<({IconData symbol, String label, String? skinSlot})> specs;
  final int currentIndex;
  final String activeSkin;
  final ValueChanged<int> onSelect;

  const _FloatingBottomBar({
    required this.specs,
    required this.currentIndex,
    required this.activeSkin,
    required this.onSelect,
  });

  @override
  State<_FloatingBottomBar> createState() => _FloatingBottomBarState();
}

class _FloatingBottomBarState extends State<_FloatingBottomBar> {
  int _pressedIndex = -1;

  Widget _icon(int index, {required bool selected}) {
    final spec = widget.specs[index];
    Widget fallback({required bool sel}) =>
        Icon(spec.symbol, size: 24, fill: sel ? 1 : 0);
    if (widget.activeSkin.isEmpty || spec.skinSlot == null) {
      return fallback(sel: selected);
    }
    return _SkinIcon(
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
    // [UI_SYNC_REFACTOR R1] 毛玻璃：enableBlur 开启时半透明底（blurAlpha/255）
    // + BackdropFilter（blurRadius）；关闭维持实色 α0.85
    final ui = uiSettingsListenable.value;
    final useBlur = ui.enableBlur;
    final capsule = Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      height: 64,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(
          alpha: useBlur ? ui.bottomBarBlurAlpha / 255 : 0.85,
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
      if (useBlur) {
        return SafeArea(
          top: false,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: ui.bottomBarBlurRadius.toDouble(),
                sigmaY: ui.bottomBarBlurRadius.toDouble(),
              ),
              child: capsule,
            ),
          ),
        );
      }
      return SafeArea(top: false, child: capsule);
  }
}
