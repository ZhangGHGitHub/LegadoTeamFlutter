// [设置批2b-2a | 2026-11-02] 首页与导航偏好 Notifier 测试
//
// 覆盖：默认值 / 显隐 / 隐藏默认页回落 / 顺序 / 自定义图标 / 恢复默认 /
// 备份 appPrefs 往返。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/main_tab.dart';
import 'package:flutter_legado/src/providers/main_prefs_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> containerWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(mainPrefsProvider.notifier).loadFuture;
    return container;
  }

  test('加载期间 dispose：异步读取完成后不再写 state/抛异常', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    final notifier = container.read(mainPrefsProvider.notifier);
    final loadFuture = notifier.loadFuture!;
    container.dispose();
    // 不抛 StateError: Cannot use "state" after dispose
    await loadFuture;
  });

  group('默认值（对齐参考版 AppShellSettings）', () {
    test('空偏好：显示全部页签 / 默认书架 / 默认顺序 / 无自定义图标', () async {
      final container = await containerWith({});
      final state = container.read(mainPrefsProvider);
      expect(state.loaded, isTrue);
      expect(state.showHome, isTrue);
      expect(state.showDiscovery, isTrue);
      expect(state.showRss, isTrue);
      expect(state.defaultHomePage, 'bookshelf');
      expect(state.navigationOrder, kDefaultMainNavigationOrder);
      expect(state.visibleTabs, kDefaultMainTabOrder);
      expect(state.navIconPaths, isEmpty);
      expect(state.navIconSelectedPaths, isEmpty);
    });

    test('旧备份的 showDiscovery/showRss/defaultHomePage 继续生效', () async {
      final container = await containerWith({
        PrefKeys.showDiscovery: false,
        PrefKeys.showRss: false,
        PrefKeys.defaultHomePage: 'my',
      });
      final state = container.read(mainPrefsProvider);
      expect(state.visibleTabs, [MainTab.home, MainTab.bookshelf, MainTab.my]);
      expect(state.defaultHomePage, 'my');
    });
  });

  group('显隐', () {
    test('隐藏发现：从可见列表移除并持久化', () async {
      final container = await containerWith({});
      await container.read(mainPrefsProvider.notifier).setShowDiscovery(false);
      final state = container.read(mainPrefsProvider);
      expect(state.showDiscovery, isFalse);
      expect(state.visibleTabs, isNot(contains(MainTab.explore)));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.showDiscovery), isFalse);
    });

    test('隐藏当前默认页：默认首页回落 bookshelf', () async {
      final container = await containerWith({
        PrefKeys.defaultHomePage: 'explore',
      });
      await container.read(mainPrefsProvider.notifier).setShowDiscovery(false);
      final state = container.read(mainPrefsProvider);
      expect(state.defaultHomePage, 'bookshelf');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.defaultHomePage), 'bookshelf');
    });

    test('隐藏项挪到顺序末尾（重新显示从末尾出现）', () async {
      final container = await containerWith({});
      await container.read(mainPrefsProvider.notifier).setShowHome(false);
      expect(container.read(mainPrefsProvider).orderedTabs, [
        MainTab.bookshelf,
        MainTab.explore,
        MainTab.rss,
        MainTab.my,
        MainTab.home,
      ]);
      await container.read(mainPrefsProvider.notifier).setShowHome(true);
      expect(container.read(mainPrefsProvider).visibleTabs.last, MainTab.home);
    });

    test('书架/我的不可隐藏', () async {
      final container = await containerWith({});
      final notifier = container.read(mainPrefsProvider.notifier);
      await notifier.setTabVisible(MainTab.bookshelf, false);
      await notifier.setTabVisible(MainTab.my, false);
      expect(
        container.read(mainPrefsProvider).visibleTabs,
        containsAll([MainTab.bookshelf, MainTab.my]),
      );
    });

    test('三项全隐藏后仍至少保留一项（书架/我的）', () async {
      final container = await containerWith({});
      final notifier = container.read(mainPrefsProvider.notifier);
      await notifier.setShowHome(false);
      await notifier.setShowDiscovery(false);
      await notifier.setShowRss(false);
      expect(container.read(mainPrefsProvider).visibleTabs, isNotEmpty);
    });
  });

  group('顺序', () {
    test('设置顺序：去重/补齐并持久化', () async {
      final container = await containerWith({});
      await container.read(mainPrefsProvider.notifier).setNavigationOrder([
        MainTab.my,
        MainTab.home,
        MainTab.home,
      ]);
      final state = container.read(mainPrefsProvider);
      expect(state.navigationOrder, 'my,home,bookshelf,explore,rss');
      expect(state.visibleTabs, [
        MainTab.my,
        MainTab.home,
        MainTab.bookshelf,
        MainTab.explore,
        MainTab.rss,
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PrefKeys.mainNavigationOrder),
        'my,home,bookshelf,explore,rss',
      );
    });

    test('损坏的顺序字符串在加载时被规范化', () async {
      final container = await containerWith({
        PrefKeys.mainNavigationOrder: 'bogus,rss,rss',
      });
      expect(
        container.read(mainPrefsProvider).navigationOrder,
        'rss,home,bookshelf,explore,my',
      );
    });
  });

  group('自定义图标', () {
    test('设置/清除未选中与选中图标均持久化', () async {
      final container = await containerWith({});
      final notifier = container.read(mainPrefsProvider.notifier);
      await notifier.setNavIconPath(
        MainTab.home,
        selected: false,
        path: '/icons/home.png',
      );
      await notifier.setNavIconPath(
        MainTab.home,
        selected: true,
        path: '/icons/home-selected.png',
      );
      var state = container.read(mainPrefsProvider);
      expect(state.navIconPath(MainTab.home), '/icons/home.png');
      expect(
        state.navIconPath(MainTab.home, selected: true),
        '/icons/home-selected.png',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.navIconHome), '/icons/home.png');
      expect(
        prefs.getString(PrefKeys.navIconHomeSelected),
        '/icons/home-selected.png',
      );

      await notifier.setNavIconPath(MainTab.home, selected: false, path: '');
      state = container.read(mainPrefsProvider);
      expect(state.navIconPath(MainTab.home), isEmpty);
      expect(prefs.containsKey(PrefKeys.navIconHome), isFalse);
      // 选中态不受影响
      expect(
        state.navIconPath(MainTab.home, selected: true),
        '/icons/home-selected.png',
      );
    });

    test('加载时还原 10 个图标槽位', () async {
      final container = await containerWith({
        PrefKeys.navIconHome: '/icons/home.png',
        PrefKeys.navIconRss: '/icons/rss.png',
        PrefKeys.navIconMySelected: '/icons/my-selected.png',
      });
      final state = container.read(mainPrefsProvider);
      expect(state.navIconPath(MainTab.home), '/icons/home.png');
      expect(state.navIconPath(MainTab.rss), '/icons/rss.png');
      expect(
        state.navIconPath(MainTab.my, selected: true),
        '/icons/my-selected.png',
      );
      expect(state.navIconPath(MainTab.bookshelf), isEmpty);
      expect(state.navIconPath(MainTab.explore), isEmpty);
    });
  });

  group('恢复默认', () {
    test('重置显隐/顺序/默认首页/图标并清理持久化键', () async {
      final container = await containerWith({
        PrefKeys.showHome: false,
        PrefKeys.showDiscovery: false,
        PrefKeys.showRss: false,
        PrefKeys.defaultHomePage: 'my',
        PrefKeys.mainNavigationOrder: 'my,rss,bookshelf,explore,home',
        PrefKeys.navIconHome: '/icons/home.png',
        PrefKeys.navIconMySelected: '/icons/my-selected.png',
      });
      await container
          .read(mainPrefsProvider.notifier)
          .resetNavigationSettings();
      final state = container.read(mainPrefsProvider);
      expect(state.showHome, isTrue);
      expect(state.showDiscovery, isTrue);
      expect(state.showRss, isTrue);
      expect(state.defaultHomePage, 'bookshelf');
      expect(state.navigationOrder, kDefaultMainNavigationOrder);
      expect(state.navIconPaths, isEmpty);
      expect(state.navIconSelectedPaths, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        PrefKeys.showHome,
        PrefKeys.showDiscovery,
        PrefKeys.showRss,
        PrefKeys.defaultHomePage,
        PrefKeys.mainNavigationOrder,
        PrefKeys.navIconHome,
        PrefKeys.navIconMySelected,
      ]) {
        expect(prefs.containsKey(key), isFalse, reason: key);
      }
    });
  });

  group('备份 appPrefs 往返', () {
    test('导航键随 collectForBackup 导出（不属主题忽略组）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.showHome: false,
        PrefKeys.mainNavigationOrder: 'rss,home,bookshelf,explore,my',
        PrefKeys.defaultHomePage: 'rss',
        PrefKeys.navIconRss: '/icons/rss.png',
      });
      final collected = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(collected[PrefKeys.showHome], isFalse);
      expect(
        collected[PrefKeys.mainNavigationOrder],
        'rss,home,bookshelf,explore,my',
      );
      expect(collected[PrefKeys.defaultHomePage], 'rss');
      expect(collected[PrefKeys.navIconRss], '/icons/rss.png');

      // 勾选「忽略主题配置」也不应过滤导航键（参考版 themePrefKeys 未收录）
      final themeIgnored = await RestoreIgnorePrefs.collectForBackup(const {
        'themeConfig': true,
      });
      expect(themeIgnored.containsKey(PrefKeys.showHome), isTrue);
      expect(themeIgnored.containsKey(PrefKeys.navIconRss), isTrue);
    });

    test('恢复 appPrefs 后 Notifier 重载得到备份配置', () async {
      SharedPreferences.setMockInitialValues({});
      await RestoreIgnorePrefs.applyFromBackup({
        PrefKeys.showHome: false,
        PrefKeys.showDiscovery: false,
        PrefKeys.showRss: false,
        PrefKeys.mainNavigationOrder: 'my,bookshelf,home,explore,rss',
        PrefKeys.defaultHomePage: 'my',
        PrefKeys.navIconHomeSelected: '/backup/home-selected.png',
      }, const {});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(mainPrefsProvider.notifier).loadFuture;
      final state = container.read(mainPrefsProvider);
      expect(state.showHome, isFalse);
      expect(state.navigationOrder, 'my,bookshelf,home,explore,rss');
      expect(state.visibleTabs, [MainTab.my, MainTab.bookshelf]);
      expect(state.defaultHomePage, 'my');
      expect(
        state.navIconPath(MainTab.home, selected: true),
        '/backup/home-selected.png',
      );
    });

    test('备份缺省导航键不覆盖本机 false（有意缺省语义）', () async {
      // 旧备份/未落盘的默认键：applyFromBackup 只写备份中存在的键，
      // 缺失的 showDiscovery 不重置本机 false。此为有意语义：缺省=不覆盖。
      SharedPreferences.setMockInitialValues({PrefKeys.showDiscovery: false});
      await RestoreIgnorePrefs.applyFromBackup({
        PrefKeys.mainNavigationOrder: 'my,bookshelf',
      }, const {});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.showDiscovery), isFalse);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(mainPrefsProvider.notifier).loadFuture;
      final state = container.read(mainPrefsProvider);
      expect(state.showDiscovery, isFalse);
      expect(state.visibleTabs, isNot(contains(MainTab.explore)));
      expect(state.navigationOrder, 'my,bookshelf,home,explore,rss');
    });
  });
}
