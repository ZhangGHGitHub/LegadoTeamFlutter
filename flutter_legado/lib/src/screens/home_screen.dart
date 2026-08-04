import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../l10n/app_strings.dart';
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
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 底栏双击判定窗口（对标原版 bookshelfReselected/exploreReselected 300ms）
  static const _reselectInterval = Duration(milliseconds: 300);

  /// 返回键双击退出判定窗口（对标原版 EXIT_INTERVAL = 2000ms）
  static const _exitInterval = Duration(seconds: 2);

  final PageController _pageController = PageController();
  int _currentIndex = 0;

  /// 已访问过的 Tab 索引集合（首屏默认访问书架）— 保留懒构建语义
  final Set<int> _visitedTabs = {0};

  /// 书架页回滚顶部信号（双击书架底栏项时自增）
  final ValueNotifier<int> _bookshelfScrollTopSignal = ValueNotifier(0);

  /// 发现页收起展开项信号（双击发现底栏项时自增）
  final ValueNotifier<int> _exploreCollapseSignal = ValueNotifier(0);

  DateTime? _lastTapTime;
  int _lastTapIndex = -1;
  DateTime? _lastBackTime;

  @override
  void dispose() {
    _pageController.dispose();
    _bookshelfScrollTopSignal.dispose();
    _exploreCollapseSignal.dispose();
    super.dispose();
  }

  void _onDestinationSelected(int index) {
    final now = DateTime.now();
    // 双击检测：300ms 内再次点击当前选中项 → 触发 reselect 动作
    if (index == _currentIndex &&
        _lastTapIndex == index &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!) <= _reselectInterval) {
      _lastTapTime = null;
      _onReselect(index);
      return;
    }
    _lastTapTime = now;
    _lastTapIndex = index;
    if (index != _currentIndex) {
      // 对标原版 setCurrentItem(position, false)：无过渡动画
      _pageController.jumpToPage(index);
    }
  }

  /// 底栏双击动作（对标 onNavigationItemReselected）
  void _onReselect(int index) {
    switch (index) {
      case 0: // 书架：gotoTop
        _bookshelfScrollTopSignal.value++;
      case 1: // 发现：compressExplore（收起已展开的分类）
        _exploreCollapseSignal.value++;
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _visitedTabs.add(index);
    });
  }

  /// 返回键两段式处理（对标 MainActivity.onBackPressedDispatcher）
  Future<void> _handleBack() async {
    if (_currentIndex != 0) {
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        // SafeArea 覆盖手势导航与刘海屏场景
        // bottom: false — 底部 NavigationBar 已自带 SafeArea 处理
        // 阅读器为独立路由页面（沉浸式），不受此处影响
        body: SafeArea(
          bottom: false,
          child: PageView(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            children: [
              BookshelfScreen(scrollTopSignal: _bookshelfScrollTopSignal),
              if (_visitedTabs.contains(1))
                ExploreScreen(collapseSignal: _exploreCollapseSignal)
              else
                const SizedBox.shrink(),
              if (_visitedTabs.contains(2))
                const RssScreen()
              else
                const SizedBox.shrink(),
              if (_visitedTabs.contains(3))
                const SettingsScreen()
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
          selectedIndex: _currentIndex,
          onDestinationSelected: _onDestinationSelected,
          destinations: [
            NavigationDestination(
              icon: SvgPicture.asset(
                'assets/icons/ic_bottom_books_e.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.onSurfaceVariant,
                  BlendMode.srcIn,
                ),
              ),
              selectedIcon: SvgPicture.asset(
                'assets/icons/ic_bottom_books_s.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.primary,
                  BlendMode.srcIn,
                ),
              ),
              label: AppStrings.bookshelf,
            ),
            NavigationDestination(
              icon: SvgPicture.asset(
                'assets/icons/ic_bottom_explore_e.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.onSurfaceVariant,
                  BlendMode.srcIn,
                ),
              ),
              selectedIcon: SvgPicture.asset(
                'assets/icons/ic_bottom_explore_s.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.primary,
                  BlendMode.srcIn,
                ),
              ),
              label: AppStrings.discover,
            ),
            NavigationDestination(
              icon: SvgPicture.asset(
                'assets/icons/ic_bottom_rss_feed_e.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.onSurfaceVariant,
                  BlendMode.srcIn,
                ),
              ),
              selectedIcon: SvgPicture.asset(
                'assets/icons/ic_bottom_rss_feed_s.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.primary,
                  BlendMode.srcIn,
                ),
              ),
              label: AppStrings.rss,
            ),
            NavigationDestination(
              icon: SvgPicture.asset(
                'assets/icons/ic_bottom_person_e.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.onSurfaceVariant,
                  BlendMode.srcIn,
                ),
              ),
              selectedIcon: SvgPicture.asset(
                'assets/icons/ic_bottom_person_s.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.primary,
                  BlendMode.srcIn,
                ),
              ),
              label: AppStrings.my,
            ),
          ],
        ),
      ),
    );
  }
}
