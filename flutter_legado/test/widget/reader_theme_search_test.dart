// 阅读主题列表搜索（批8b）
//
// 覆盖：名称不区分大小写过滤（内置+自建）、清除、无匹配空态、
// 网格/列表共用过滤结果、管理态全选仅可见、搜索变化裁剪选择、
// 当前主题被过滤隐藏时定位不报错、360dp 无溢出。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/reader_theme.dart';
import 'package:flutter_legado/src/screens/reader_theme_screen.dart';
import 'package:flutter_legado/src/services/reader_theme_service.dart';

void main() {
  late ProviderContainer container;

  const style = ReaderThemeStyle();
  final customThemes = <ReaderTheme>[
    const ReaderTheme(id: 'custom-alpha', name: 'Alpha', style: style),
    const ReaderTheme(id: 'custom-beta', name: 'Beta', style: style),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({
      ReaderThemeService.themesKey: ReaderThemeCodec.encodeStoredList(
        customThemes,
      ),
      ReaderThemeService.currentIdKey: 'custom-alpha',
    });
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ReaderThemeScreen()),
    );
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
  }

  Future<void> enterManage(WidgetTester tester) async {
    await tester.tap(find.byTooltip('管理主题'));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const ValueKey('reader-theme-search')),
      text,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('搜索按名称不区分大小写过滤内置与自建主题，清空恢复', (tester) async {
    await pumpScreen(tester);
    expect(find.text('搜索主题（共 7 个）'), findsOneWidget);

    await search(tester, '预设');
    expect(find.byType(ReaderThemeCard), findsNWidgets(4));
    expect(find.text('预设1'), findsOneWidget);
    expect(find.text('微信读书'), findsNothing);
    expect(find.text('新建主题'), findsNothing);

    await search(tester, 'ALPHA');
    expect(find.byType(ReaderThemeCard), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-theme-search-clear')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderThemeCard), findsNWidgets(7));
    expect(find.text('新建主题'), findsOneWidget);
    expect(find.text('搜索主题（共 7 个）'), findsOneWidget);
  });

  testWidgets('无匹配显示空态且不显示新建卡', (tester) async {
    await pumpScreen(tester);

    await search(tester, '不存在的主题');
    expect(
      find.byKey(const ValueKey('reader-theme-search-empty')),
      findsOneWidget,
    );
    expect(find.text('没有匹配的主题'), findsOneWidget);
    expect(find.byType(ReaderThemeCard), findsNothing);
    expect(find.text('新建主题'), findsNothing);
  });

  testWidgets('网格与列表布局共用过滤结果', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'alpha');

    expect(find.byType(ReaderThemeCard), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);

    await tester.tap(find.byTooltip('切换为列表'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderThemeChip), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    expect(find.text('新建主题'), findsNothing);
  });

  testWidgets('管理态全选只作用于过滤后可见的自建主题', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'Alpha');
    await enterManage(tester);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);
  });

  testWidgets('搜索变化裁剪已选中但不可见的主题', (tester) async {
    await pumpScreen(tester);
    await enterManage(tester);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2'), findsOneWidget);

    await search(tester, 'Beta');
    expect(find.text('已选 1'), findsOneWidget);

    await search(tester, '无匹配');
    expect(find.text('已选 0'), findsOneWidget);
    expect(find.text('没有匹配的主题'), findsOneWidget);
  });

  testWidgets('当前主题被过滤隐藏时定位当前不报错', (tester) async {
    await pumpScreen(tester);
    await search(tester, 'Beta');

    await tester.tap(find.byTooltip('定位当前'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('360dp 搜索框与管理态不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpScreen(tester);
    await search(tester, 'Alpha');
    await enterManage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('已选 0'), findsOneWidget);
  });
}
