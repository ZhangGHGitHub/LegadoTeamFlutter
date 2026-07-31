import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../l10n/app_strings.dart';
import 'bookshelf_screen.dart';
import 'explore_screen.dart';
import 'rss_screen.dart';
import 'settings_screen.dart';

/// 首页 - 底部 Tab 导航
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  /// 已访问过的 Tab 索引集合（首屏默认访问书架）
  final Set<int> _visitedTabs = {0};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // SafeArea 覆盖手势导航与刘海屏场景
      // bottom: false — 底部 NavigationBar 已自带 SafeArea 处理
      // 阅读器为独立路由页面（沉浸式），不受此处影响
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _currentIndex,
          children: [
            const BookshelfScreen(),
            if (_visitedTabs.contains(1)) const ExploreScreen() else const SizedBox.shrink(),
            if (_visitedTabs.contains(2)) const RssScreen() else const SizedBox.shrink(),
            if (_visitedTabs.contains(3)) const SettingsScreen() else const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
            _visitedTabs.add(index);
          });
        },
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
                Theme.of(context).colorScheme.onSecondaryContainer,
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
                Theme.of(context).colorScheme.onSecondaryContainer,
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
                Theme.of(context).colorScheme.onSecondaryContainer,
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
                Theme.of(context).colorScheme.onSecondaryContainer,
                BlendMode.srcIn,
              ),
            ),
            label: AppStrings.my,
          ),
        ],
      ),
    );
  }
}
