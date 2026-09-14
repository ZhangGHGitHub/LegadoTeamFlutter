// 搜索页顶栏溢出回归测试（差异清单 A1 缺陷：A1 三钮加入后，
// M3 SearchBar 默认 minWidth 360 在 360dp 屏 + 多顶栏钮下撑爆 AppBar，
// 胶囊输入条被压到无法输入）。修复 = SearchBar constraints.minWidth 0。
//
// 装配复用 search_screen_scroll_test 的 mock 模式。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
        .thenAnswer((_) async => []);
    when(() => mockApi.addSearchKeyword(any(), any()))
        .thenAnswer((_) async {});
    when(() => mockApi.clearSearchHistory()).thenAnswer((_) async {});
    when(() => mockApi.cancelSearch()).thenAnswer((_) async {});
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.getEnabledBookSources())
        .thenAnswer((_) async => []);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpAt360(WidgetTester tester) async {
    // 对齐 MuMu Test 实例：1080 物理宽 @ dpr3 = 360dp 逻辑宽
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: const SearchScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('360dp 下顶栏不溢出、输入条在位且可输入', (tester) async {
    await pumpAt360(tester);
    // 布局溢出（RenderFlex overflow）会以异常形式被框架捕获：
    // 断言无异常即断言顶栏（返回+3 动作钮，[1-6 ①] 2.0.259 4→3）
    // 与 body 顶部输入条在 360dp 下放得下
    expect(tester.takeException(), isNull);
    // 输入条可输入
    await tester.enterText(find.byType(TextField).first, '斗罗大陆');
    await tester.pump();
    expect(find.text('斗罗大陆'), findsOneWidget);
  });

  testWidgets('360dp 下输入后提交（IME 搜索动作）不溢出', (tester) async {
    await pumpAt360(tester);
    await tester.enterText(find.byType(TextField).first, '斗罗大陆');
    await tester.pump();
    // IME 搜索动作提交（onSubmitted → search）——溢出若存在会在此抛出
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
