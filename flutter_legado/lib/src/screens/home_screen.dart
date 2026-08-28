import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_strings.dart';
import '../providers/bottom_bar_skin_notifier.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/theme/system_bar_notifier.dart';
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
      _pageController.jumpToPage(index);
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
  Future<void> _handleBack() async {
    if (_currentTab != _HomeTab.bookshelf) {
      _pageController.jumpToPage(0);
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
          if (mounted && _pageController.hasClients) {
            _pageController.jumpToPage(targetIndex);
          }
        });
      }
    });
    // Tab 显隐变化后当前 Tab 可能被隐藏，回退书架并同步页面位置
    var currentIndex = tabs.indexOf(_currentTab);
    if (currentIndex < 0) {
      _currentTab = _HomeTab.bookshelf;
      currentIndex = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(0);
        }
      });
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        // 沉浸式状态栏开启时顶栏延伸至状态栏区域（对标原版 fullScreen +
        // AppConfig.isTransparentStatusBar）；关闭时保留顶部 SafeArea
        body: SafeArea(
          top: !ref.watch(systemBarProvider.select((s) => s.transparentStatusBar)),
          bottom: false,
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) => _onPageChanged(tabs, index),
            children: [for (final tab in tabs) _pageOf(tab)],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          // labelBehavior 缺省走主题（alwaysShow，M3 标准）；
          // 双击重选 300ms / 两段式退出 2000ms 交互不变（home_navigation_test 守护）
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
