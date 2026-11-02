// [设置批2b-2a | 2026-11-02] 「首页与导航」设置 Sheet 交互测试
//
// 覆盖：默认值 / 显隐开关 / 默认首页下拉 / 底栏文字下拉 / 拖拽排序接线 /
// 图标管理入口 / 恢复默认（含底栏文字）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/main_tab.dart';
import 'package:flutter_legado/src/providers/main_prefs_notifier.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/main_navigation_settings_sheet.dart';

void main() {
  Future<ProviderContainer> pumpSheet(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _SheetHost())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MainNavigationSettingsSheet)),
    );
  }

  testWidgets('默认值：五个导航项、默认首页书架、底栏文字自动', (tester) async {
    final container = await pumpSheet(tester);
    expect(find.text('首页与导航'), findsOneWidget);
    for (final tab in MainTab.values) {
      expect(find.byKey(ValueKey('nav-item-${tab.route}')), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byType(DropdownButton<String>),
        matching: find.text('书架'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(DropdownButton<BottomBarLabelMode>),
        matching: find.text('自动（默认）'),
      ),
      findsOneWidget,
    );
    expect(container.read(mainPrefsProvider).visibleTabs, kDefaultMainTabOrder);
  });

  testWidgets('显隐开关：关闭发现后立即从可见列表移除并持久化', (tester) async {
    final container = await pumpSheet(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('nav-item-explore')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(mainPrefsProvider).showDiscovery, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.showDiscovery), isFalse);
    expect(
      container.read(mainPrefsProvider).visibleTabs,
      isNot(contains(MainTab.explore)),
    );
    // 隐藏项仍在列表中（置底、无拖拽把手）
    expect(find.byKey(const ValueKey('nav-item-explore')), findsOneWidget);
  });

  testWidgets('书架/我的开关禁用（始终显示）', (tester) async {
    await pumpSheet(tester);
    for (final tab in [MainTab.bookshelf, MainTab.my]) {
      final row = find.byKey(ValueKey('nav-item-${tab.route}'));
      final switchWidget = tester.widget<Switch>(
        find.descendant(of: row, matching: find.byType(Switch)),
      );
      expect(switchWidget.onChanged, isNull);
      expect(
        find.descendant(of: row, matching: find.text('始终显示')),
        findsOneWidget,
      );
    }
  });

  testWidgets('默认首页下拉仅列可见项并可切换', (tester) async {
    final container = await pumpSheet(tester, prefs: {PrefKeys.showRss: false});
    final dropdownFinder = find.byType(DropdownButton<String>);
    final dropdown = tester.widget<DropdownButton<String>>(dropdownFinder);
    expect(
      dropdown.items!.map((item) => item.value),
      isNot(contains(MainTab.rss.route)),
    );
    await tester.tap(dropdownFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(container.read(mainPrefsProvider).defaultHomePage, 'my');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.defaultHomePage), 'my');
  });

  testWidgets('底栏文字下拉切换为全部常显', (tester) async {
    final container = await pumpSheet(tester);
    await tester.tap(find.byType(DropdownButton<BottomBarLabelMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部常显').last);
    await tester.pumpAndSettle();
    expect(
      container.read(uiSettingsProvider).labelVisibilityMode,
      BottomBarLabelMode.labeled,
    );
  });

  testWidgets('拖拽排序接线：onReorderItem 更新 mainNavigationOrder', (tester) async {
    final container = await pumpSheet(tester);
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    // onReorderItem 的 newIndex 已由框架调整：首页(0) → 位置 2
    list.onReorderItem!(0, 2);
    await tester.pumpAndSettle();
    expect(
      container.read(mainPrefsProvider).navigationOrder,
      'bookshelf,explore,home,rss,my',
    );
  });

  testWidgets('导航栏图标入口：打开图标管理（5 页签 × 2 槽）', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('导航栏图标'));
    await tester.pumpAndSettle();
    expect(find.text('未选中'), findsOneWidget);
    expect(find.text('选中'), findsOneWidget);
    // 10 个空槽位均显示添加图标
    expect(find.byIcon(Symbols.add_rounded), findsNWidgets(10));
    for (final tab in MainTab.values) {
      expect(find.text(mainTabLabel(tab)), findsWidgets);
    }
  });

  testWidgets('恢复默认：重置显隐/顺序/底栏文字并清理偏好键', (tester) async {
    final container = await pumpSheet(
      tester,
      prefs: {
        PrefKeys.showHome: false,
        PrefKeys.mainNavigationOrder: 'my,rss,bookshelf,explore,home',
        PrefKeys.defaultHomePage: 'my',
        PrefKeys.labelVisibilityMode: 'unlabeled',
        PrefKeys.navIconHome: '/icons/home.png',
      },
    );
    expect(container.read(mainPrefsProvider).showHome, isFalse);

    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '恢复默认'));
    await tester.pumpAndSettle();

    final state = container.read(mainPrefsProvider);
    expect(state.showHome, isTrue);
    expect(state.navigationOrder, kDefaultMainNavigationOrder);
    expect(state.defaultHomePage, 'bookshelf');
    expect(state.navIconPaths, isEmpty);
    expect(
      container.read(uiSettingsProvider).labelVisibilityMode,
      BottomBarLabelMode.auto,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(PrefKeys.showHome), isFalse);
    expect(prefs.containsKey(PrefKeys.navIconHome), isFalse);
  });
}

class _SheetHost extends StatelessWidget {
  const _SheetHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => MainNavigationSettingsSheet.show(context),
            child: const Text('打开'),
          ),
        ),
      ),
    );
  }
}
