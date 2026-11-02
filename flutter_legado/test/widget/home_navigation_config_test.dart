// [设置批2b-2a | 2026-11-02] 首页动态导航构建测试
//
// 覆盖：默认五页签 / 显隐 / 顺序 / 默认首页 / 当前页被隐藏回退首个可见 /
// 底栏文字档位 / 自定义图标渲染 / 重启后保持 / 返回键与路由压栈兼容。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/main_tab.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/main_prefs_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/home_tab_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/widgets/navigation/app_navigation_bars.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  MockRustApi buildApi() {
    final api = MockRustApi();
    when(() => api.getBooks()).thenAnswer(
      (_) async => [
        for (var i = 0; i < 30; i++) Book(bookUrl: 'u$i', name: '书籍$i'),
      ],
    );
    when(() => api.getBookGroups()).thenAnswer((_) async => []);
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    when(() => api.getRssSources()).thenAnswer((_) async => []);
    when(() => api.getReadRecords()).thenAnswer((_) async => []);
    when(() => api.readRecordDailyList(any())).thenAnswer((_) async => []);
    return api;
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    required Map<String, Object> prefs,
    required MockRustApi api,
    bool resetPrefs = true,
    bool settle = true,
  }) async {
    if (resetPrefs) SharedPreferences.setMockInitialValues(prefs);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // 自定义图标会让 Image.file 进入真实异步解码；fake-async 下不等待
      // 解码完成，仅推进偏好加载所需的若干帧后断言规格接线。
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
    }
  }

  Future<void> pumpFresh(WidgetTester tester, MockRustApi api) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  int selectedIndex(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  List<String> destinationLabels(WidgetTester tester) => tester
      .widgetList<NavigationDestination>(find.byType(NavigationDestination))
      .map((d) => d.label)
      .toList(growable: false);

  MainPrefsNotifier prefsNotifier(WidgetTester tester) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    return container.read(mainPrefsProvider.notifier);
  }

  testWidgets('默认配置：五页签、书架落点不变（回归）', (tester) async {
    await pumpHome(tester, prefs: {}, api: buildApi());
    expect(destinationLabels(tester), ['首页', '书架', '发现', '订阅', '我的']);
    expect(selectedIndex(tester), 1);
    expect(find.byType(BookshelfScreen), findsOneWidget);
  });

  testWidgets('显隐：首页/发现/订阅全隐藏后仅剩书架与我的', (tester) async {
    await pumpHome(
      tester,
      prefs: {
        PrefKeys.showHome: false,
        PrefKeys.showDiscovery: false,
        PrefKeys.showRss: false,
      },
      api: buildApi(),
    );
    expect(destinationLabels(tester), ['书架', '我的']);
    expect(selectedIndex(tester), 0);
    expect(find.byType(BookshelfScreen), findsOneWidget);
  });

  testWidgets('顺序：按 mainNavigationOrder 构建底栏，默认页按新索引落点', (tester) async {
    await pumpHome(
      tester,
      prefs: {PrefKeys.mainNavigationOrder: 'my,home,bookshelf,explore,rss'},
      api: buildApi(),
    );
    expect(destinationLabels(tester), ['我的', '首页', '书架', '发现', '订阅']);
    expect(selectedIndex(tester), 2);
    expect(find.byType(BookshelfScreen), findsOneWidget);
  });

  testWidgets('默认首页：explore 在加载后切到发现页', (tester) async {
    await pumpHome(
      tester,
      prefs: {PrefKeys.defaultHomePage: 'explore'},
      api: buildApi(),
    );
    expect(selectedIndex(tester), 2);
    expect(find.byType(ExploreScreen), findsOneWidget);
  });

  testWidgets('默认首页被隐藏：落回首个可见页签（索引 0）', (tester) async {
    await pumpHome(
      tester,
      prefs: {PrefKeys.defaultHomePage: 'rss', PrefKeys.showRss: false},
      api: buildApi(),
    );
    // 顺序中 rss 仍第 5 且隐藏；默认页不可见 → initialPage 回退 0（首页）
    expect(destinationLabels(tester), ['首页', '书架', '发现', '我的']);
    expect(selectedIndex(tester), 0);
    expect(find.byType(HomeTabScreen), findsOneWidget);
  });

  testWidgets('默认首页不可见且首个可见项不是书架：落点仍是索引 0', (tester) async {
    await pumpHome(
      tester,
      prefs: {
        PrefKeys.mainNavigationOrder: 'my,explore,bookshelf,home,rss',
        PrefKeys.defaultHomePage: 'rss',
        PrefKeys.showRss: false,
      },
      api: buildApi(),
    );
    expect(destinationLabels(tester), ['我的', '发现', '书架', '首页']);
    expect(selectedIndex(tester), 0);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('当前页被隐藏：回退首个可见页签', (tester) async {
    await pumpHome(
      tester,
      prefs: {PrefKeys.defaultHomePage: 'explore'},
      api: buildApi(),
    );
    expect(selectedIndex(tester), 2);

    await prefsNotifier(tester).setShowDiscovery(false);
    await tester.pumpAndSettle();

    expect(destinationLabels(tester), ['首页', '书架', '订阅', '我的']);
    expect(selectedIndex(tester), 0);
    expect(find.byType(HomeTabScreen), findsOneWidget);
  });

  testWidgets('底栏文字：unlabeled/selected 档位映射到 NavigationBar', (tester) async {
    await pumpHome(
      tester,
      prefs: {PrefKeys.labelVisibilityMode: 'unlabeled'},
      api: buildApi(),
    );
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
      NavigationDestinationLabelBehavior.alwaysHide,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    await container
        .read(uiSettingsProvider.notifier)
        .setLabelVisibilityMode(BottomBarLabelMode.selected);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
      NavigationDestinationLabelBehavior.onlyShowSelected,
    );
  });

  testWidgets('自定义导航图标：图标路径透传到 NavSpecIcon', (tester) async {
    const iconPath = r'C:\legado-test\nav-home.png';
    await pumpHome(
      tester,
      prefs: {PrefKeys.navIconHome: iconPath},
      api: buildApi(),
      settle: false,
    );

    final icons = tester.widgetList<NavSpecIcon>(find.byType(NavSpecIcon));
    expect(
      icons.any((icon) => icon.spec.customIconPath == iconPath),
      isTrue,
      reason: '首页导航项应携带自定义图标路径',
    );
    // 其余页签仍为内置图标（空路径）
    expect(
      icons.any(
        (icon) => icon.spec.label == '书架' && icon.spec.customIconPath.isEmpty,
      ),
      isTrue,
    );
  });

  testWidgets('重启（重新挂载）：顺序与显隐保持', (tester) async {
    final api = buildApi();
    await pumpHome(tester, prefs: {}, api: api);
    await prefsNotifier(tester).setNavigationOrder([
      MainTab.my,
      MainTab.home,
      MainTab.bookshelf,
      MainTab.explore,
      MainTab.rss,
    ]);
    await prefsNotifier(tester).setShowRss(false);
    await tester.pumpAndSettle();
    expect(destinationLabels(tester), ['我的', '首页', '书架', '发现']);

    // 重新挂载（不重置 SharedPreferences = 模拟进程重启）
    await pumpFresh(tester, api);
    expect(destinationLabels(tester), ['我的', '首页', '书架', '发现']);
    expect(selectedIndex(tester), 2);
  });

  testWidgets('顺序变化：书架页 State（滚动位置）跟随页签保持', (tester) async {
    await pumpHome(tester, prefs: {}, api: buildApi());
    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    await tester.drag(scrollable, const Offset(0, -600));
    await tester.pumpAndSettle();
    final before =
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0));

    // 书架从索引 1 移到索引 2：PageView 按 ValueKey 保留各页 State
    await prefsNotifier(tester).setNavigationOrder([
      MainTab.home,
      MainTab.my,
      MainTab.bookshelf,
      MainTab.explore,
      MainTab.rss,
    ]);
    await tester.pumpAndSettle();

    expect(selectedIndex(tester), 2);
    expect(find.byType(BookshelfScreen), findsOneWidget);
    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after, before, reason: '排序不应重建书架页/丢滚动位置');
  });

  testWidgets('备份恢复同会话：applyFromBackup + invalidate 立即刷新底栏', (tester) async {
    await pumpHome(tester, prefs: {}, api: buildApi());
    expect(destinationLabels(tester).length, 5);

    await RestoreIgnorePrefs.applyFromBackup(
      {
        PrefKeys.showHome: false,
        PrefKeys.showDiscovery: false,
        PrefKeys.showRss: false,
        PrefKeys.mainNavigationOrder: 'my,bookshelf',
        PrefKeys.defaultHomePage: 'my',
      },
      const {},
    );
    final container =
        ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
    container.invalidate(mainPrefsProvider);
    await tester.pumpAndSettle();

    expect(destinationLabels(tester), ['我的', '书架']);
    // 启动默认页仅冷启动应用一次；同会话保持当前书架页（新索引 1）
    expect(selectedIndex(tester), 1);
    expect(find.byType(BookshelfScreen), findsOneWidget);
  });

  testWidgets('返回键：顺序变化后仍按书架新索引回退', (tester) async {
    await pumpHome(
      tester,
      prefs: {PrefKeys.mainNavigationOrder: 'my,home,bookshelf,explore,rss'},
      api: buildApi(),
    );
    expect(selectedIndex(tester), 2);

    await tester.tap(find.byType(NavigationDestination).at(0));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(selectedIndex(tester), 2);
    expect(find.byType(BookshelfScreen), findsOneWidget);
  });

  testWidgets('路由压栈/出栈（深链等外页）后当前页签保持', (tester) async {
    await pumpHome(
      tester,
      prefs: {PrefKeys.mainNavigationOrder: 'my,home,bookshelf,explore,rss'},
      api: buildApi(),
    );
    await tester.tap(find.byType(NavigationDestination).at(0));
    await tester.pumpAndSettle();
    expect(selectedIndex(tester), 0);

    // 模拟深链/通知打开独立页（路由压在 HomeScreen 之上）
    final navigator = Navigator.of(tester.element(find.byType(HomeScreen)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('external-route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('external-route'), findsOneWidget);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(selectedIndex(tester), 0);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
