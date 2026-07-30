import 'package:flutter/material.dart';

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
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const BookshelfScreen(),
          if (_visitedTabs.contains(1)) const ExploreScreen() else const SizedBox.shrink(),
          if (_visitedTabs.contains(2)) const RssScreen() else const SizedBox.shrink(),
          if (_visitedTabs.contains(3)) const SettingsScreen() else const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
            _visitedTabs.add(index);
          });
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.library_books_outlined),
            selectedIcon: const Icon(Icons.library_books),
            label: AppStrings.bookshelf,
          ),
          NavigationDestination(
            icon: const Icon(Icons.explore_outlined),
            selectedIcon: const Icon(Icons.explore),
            label: '发现',
          ),
          NavigationDestination(
            icon: Icon(Icons.rss_feed_outlined),
            selectedIcon: Icon(Icons.rss_feed),
            label: 'RSS',
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: AppStrings.settings,
          ),
        ],
      ),
    );
  }
}
