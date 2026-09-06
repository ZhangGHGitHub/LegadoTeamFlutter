import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/home_tab_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';

import '../mocks/mocks.dart';

/// 主框架导航对齐验证（对标原版 MainActivity：
/// PageView 滑动切页（对齐参考 HorizontalPager）+ BottomNavigationView 并存、
/// 双击回顶、返回键两段式）
/// [UI_SYNC_REFACTOR S6 | 2026-09-08] 新增首页页签后更新为五页签结构：
/// 首页(0)/书架(1)/发现(2)/订阅(3)/我的(4)，默认主页仍为书架 — Qoder
void main() {
  setUpAll(registerFallbacks);

  Future<void> pumpHome(WidgetTester tester, MockRustApi mockApi) async {
    SharedPreferences.setMockInitialValues({});
    when(() => mockApi.getBooks()).thenAnswer(
      (_) async => [
        for (var i = 0; i < 30; i++)
          Book(bookUrl: 'u$i', name: '书籍$i'),
      ],
    );
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    when(() => mockApi.getRssSources()).thenAnswer((_) async => []);
    // 首页页签数据源：阅读记录 + 每日时长（HomeTabScreen initState 拉取）
    when(() => mockApi.getReadRecords()).thenAnswer((_) async => []);
    when(() => mockApi.readRecordDailyList(any()))
        .thenAnswer((_) async => []);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  int navBarIndex(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  testWidgets('初始结构：五页签（首页/书架/发现/订阅/我的），默认落书架',
      (tester) async {
    await pumpHome(tester, MockRustApi());

    // [UI_SYNC_REFACTOR S1] 恢复 PageView 滑动切页（2026-09-05 拉参考源码
    // 核实 HorizontalPager userScrollEnabled=true，早前 IndexedStack 口径系误读；
    // 原版本就是 ViewPager 滑动）
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    // 首页页签插入后书架恒为索引 1（默认主页=书架语义不变）
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(navBarIndex(tester), 1);
    // 书架页为当前展示页面
    expect(find.byType(BookshelfScreen), findsOneWidget);
  });

  testWidgets('首页页签：点击切入并渲染最近阅读/统计/目标表盘', (tester) async {
    await pumpHome(tester, MockRustApi());

    await tester.tap(find.byType(NavigationDestination).at(0));
    await tester.pumpAndSettle();

    expect(find.byType(HomeTabScreen), findsOneWidget);
    // 「首页」文本存在于底栏标签与页内大标题多处
    expect(find.text('首页'), findsWidgets);
    expect(find.text('累计阅读'), findsOneWidget);
    expect(find.text('阅读时长'), findsOneWidget);
    expect(find.text('今日阅读目标'), findsOneWidget);
    expect(navBarIndex(tester), 0);
  });

  testWidgets('底栏切页到发现页，选中态同步（滑动切页）', (tester) async {
    await pumpHome(tester, MockRustApi());

    // [LAYOUT_MOTION_AUDIT L3] 滑动切页已禁用，切页唯一入口为底栏点击
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();

    expect(find.byType(ExploreScreen), findsOneWidget);
    expect(navBarIndex(tester), 2);
  });

  testWidgets('点击底栏项直接跳页（对标 setCurrentItem）', (tester) async {
    await pumpHome(tester, MockRustApi());

    await tester.tap(find.byType(NavigationDestination).at(4));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(navBarIndex(tester), 4);
  });

  testWidgets('返回键：非书架页先切回书架页', (tester) async {
    await pumpHome(tester, MockRustApi());

    // 先到「我的」页
    await tester.tap(find.byType(NavigationDestination).at(4));
    await tester.pumpAndSettle();
    expect(navBarIndex(tester), 4);

    await simulateBackButton(tester);
    await tester.pumpAndSettle();

    expect(navBarIndex(tester), 1);
    expect(find.text('再按一次退出程序'), findsNothing);
  });

  testWidgets('返回键：书架页首次按下弹出双击退出提示', (tester) async {
    await pumpHome(tester, MockRustApi());

    // 从首页切入书架页
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();

    await simulateBackButton(tester);
    await tester.pump();

    expect(find.text('再按一次退出程序'), findsOneWidget);
  });

  testWidgets('双击底栏书架项：列表回滚顶部（对标 gotoTop）', (tester) async {
    await pumpHome(tester, MockRustApi());

    // 从首页切入书架页
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );

    // 先向下滚动一段距离
    await tester.drag(scrollable, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(0));

    // 300ms 内双击底栏书架项
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();

    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
  });
}

/// 模拟系统返回键（触发 PopScope 回调）
Future<void> simulateBackButton(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
}
