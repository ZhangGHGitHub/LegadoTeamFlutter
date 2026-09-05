
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_strings.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../routes.dart';
import '../widgets/navigation/app_navigation_bars.dart';
import '../providers/bottom_bar_skin_notifier.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/theme/system_bar_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
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
  // [UI_SYNC_REFACTOR S1] 滑动切页控制器（对齐参考 MainScreen
  // HorizontalPager userScrollEnabled=true；2026-09-05 拉源码核实，
  // 早前审计 IndexedStack 口径系误读——原版本就是 ViewPager 滑动）
  final PageController _pageController = PageController();

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
    _pageController.dispose();
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
      // [UI_SYNC_REFACTOR S1] PageView 跳页（滑动切页开启，同参考 HorizontalPager）
      setState(() => _stackIndex = index);
      _pageController.jumpToPage(index);
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
      _pageController.jumpToPage(_stackIndex);
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
          _pageController.jumpToPage(targetIndex);
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
        _pageController.jumpToPage(0);
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
          final pageArea = PageView(
            controller: _pageController,
            // [UI_SYNC_REFACTOR S1] 滑动切页（对齐参考 HorizontalPager
            // userScrollEnabled=true；allowImplicitScrolling≈预载相邻页）
            physics: const ClampingScrollPhysics(),
            allowImplicitScrolling: true,
            onPageChanged: (index) => _onPageChanged(tabs, index),
            children: [
              for (final tab in tabs) _KeepAlivePage(child: _pageOf(tab)),
            ],
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

  /// 导航项规格（三态底栏统一消费源）
  List<AppNavSpec> _specsFor(List<_HomeTab> tabs) => [
        for (final tab in tabs)
          switch (tab) {
            _HomeTab.bookshelf => AppNavSpec(
                symbol: Symbols.menu_book_rounded,
                label: AppStrings.bookshelf,
                skinSlot: 'bookshelf',
              ),
            _HomeTab.explore => AppNavSpec(
                symbol: Symbols.explore_rounded,
                label: AppStrings.discover,
                skinSlot: 'home',
              ),
            _HomeTab.rss => AppNavSpec(
                symbol: Symbols.feed_rounded,
                label: AppStrings.rss,
                skinSlot: 'notes',
              ),
            _HomeTab.my => AppNavSpec(
                symbol: Symbols.person_rounded,
                label: AppStrings.my,
                skinSlot: 'settings',
              ),
          },
      ];

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

  /// 平板侧栏（组件化：皮肤图标+头部搜索钮+书架分组菜单+expand 持久化）
  Widget _buildRail(UiSettingsState ui, List<_HomeTab> tabs, int currentIndex) {
    final bookshelf = ref.watch(bookshelfNotifierProvider);
    return AppRailBar(
      specs: _specsFor(tabs),
      currentIndex: currentIndex,
      activeSkin: ref.watch(bottomBarSkinProvider.select((s) => s.active)),
      extended: ui.railExtended,
      onSelect: (index) => _onDestinationSelected(tabs, index),
      onToggleExtended: () => ref
          .read(uiSettingsProvider.notifier)
          .setRailExtended(!ui.railExtended),
      onSearch: () => Navigator.of(context).pushNamed(AppRoutes.search),
      groups: [
        for (final g in bookshelf.groups) g.groupName,
      ],
      selectedGroupIndex: bookshelf.selectedGroupIndex,
      onGroupSelected: (index) =>
          ref.read(bookshelfNotifierProvider.notifier).selectGroup(index),
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
      return AppFloatingBottomBar(
        specs: _specsFor(tabs),
        currentIndex: currentIndex,
        activeSkin: activeSkin,
        onSelect: (index) => _onDestinationSelected(tabs, index),
        useBlur: ui.enableBlur,
        blurRadius: ui.bottomBarBlurRadius,
        blurAlpha: ui.bottomBarBlurAlpha,
      );
    }
    return AppShortNavigationBar(
      specs: _specsFor(tabs),
      currentIndex: currentIndex,
      activeSkin: activeSkin,
      labelBehavior: switch (ui.labelVisibilityMode) {
        BottomBarLabelMode.auto =>
          NavigationDestinationLabelBehavior.onlyShowSelected,
        BottomBarLabelMode.labeled =>
          NavigationDestinationLabelBehavior.alwaysShow,
        BottomBarLabelMode.unlabeled =>
          NavigationDestinationLabelBehavior.alwaysHide,
      },
      opacity: ui.bottomBarOpacity / 100,
      onSelect: (index) => _onDestinationSelected(tabs, index),
    );
  }
}




/// [UI_SYNC_REFACTOR S1] 页保活（对齐参考 HorizontalPager
/// beyondViewportPageCount=4：全部页常驻不销毁，懒构建语义保留）
class _KeepAlivePage extends StatefulWidget {
  final Widget child;

  const _KeepAlivePage({required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
