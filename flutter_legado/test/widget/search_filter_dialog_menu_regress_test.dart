// [D1 缺陷回归 | full-stack-engineer + UI + QA]
//
// 缺陷 D1（P1，设备验收批，复现 2/2）：
// 书架 → 搜索页 → 点顶栏「搜索结果过滤」筛选钮 → 对话框点「取消」
// → 随即点 ⋮ 菜单 → 整页红屏 `'_dependents.isEmpty': is not true.`
// （framework.dart InheritedElement.debugDeactivated），UI 锁死。
// 对照路径（不经过滤弹层直接开 ⋮）正常。
//
// 本测试按原复现步骤执行顺序操作，断言：
// 1. 过滤对话框正常弹出（屏蔽词编辑框在位）；
// 2. 点「取消」后对话框关闭；
// 3. 随后打开 ⋮ 菜单无异常（tester.takeException() 为空），菜单项在位；
// 4. 连续三轮「开过滤 → 取消 → 开 ⋮」不再触发红屏断言。
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

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  /// 打开 ⋮ 菜单并断言其正常展开（无红屏异常、静态条目在位）
  Future<void> expectOverflowMenuOpen(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多选项'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: '打开 ⋮ 菜单不应抛框架断言（红屏）');
    expect(find.text('精准搜索'), findsOneWidget);
    expect(find.text('搜索结果过滤'), findsOneWidget);
    expect(find.text('书源管理'), findsOneWidget);
  }

  /// 关闭 ⋮ 菜单：点按菜单外区域（菜单锚定顶栏右侧向下展开，
  /// 测试默认画布 800x600，左下角远离菜单）
  Future<void> closeOverflowMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(40, 560));
    await tester.pumpAndSettle();
    expect(find.text('精准搜索'), findsNothing, reason: '菜单应已关闭');
  }

  group('D1 回归：过滤对话框取消后随即开 ⋮ 菜单', () {
    testWidgets('单轮：筛选 → 取消 → ⋮ 菜单无红屏', (tester) async {
      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // ① 顶栏「搜索结果过滤」筛选钮 → 弹出屏蔽词编辑对话框
      await tester.tap(find.byTooltip('搜索结果过滤'));
      await tester.pumpAndSettle();
      expect(find.text('搜索结果屏蔽词'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      // ② 点「取消」关闭对话框
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('搜索结果屏蔽词'), findsNothing);

      // ③ 随即点 ⋮ → 不应红屏
      await expectOverflowMenuOpen(tester);

      // 关闭菜单，页面可继续交互（再开一次过滤弹层验证未锁死）
      await closeOverflowMenu(tester);
      await tester.tap(find.byTooltip('搜索结果过滤'));
      await tester.pumpAndSettle();
      expect(find.text('搜索结果屏蔽词'), findsOneWidget);
    });

    testWidgets('确定路径：填写屏蔽词 → 确定 → 持久化 + 菜单仍可开',
        (tester) async {
      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 打开过滤弹层并填写屏蔽词（弹层输入框带 Key，与顶栏搜索框区分）
      await tester.tap(find.byTooltip('搜索结果过滤'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resultFilterDialogInput')),
        '广告',
      );
      await tester.pump();

      // 点「确定」→ 持久化 searchResultFilter（mock 校验写入）
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('搜索结果屏蔽词'), findsNothing);
      verify(() => mockApi.setConfig('searchResultFilter', '广告'))
          .called(1);

      // 按钮进入「已开启」态，且随后开 ⋮ 菜单仍无红屏
      expect(find.byTooltip('搜索结果过滤（已开启）'), findsOneWidget);
      await expectOverflowMenuOpen(tester);
    });

    testWidgets('三轮连做：筛选 → 取消 → ⋮ 均无红屏', (tester) async {
      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byTooltip('搜索结果过滤'));
        await tester.pumpAndSettle();
        expect(find.text('搜索结果屏蔽词'), findsOneWidget,
            reason: '第 ${i + 1} 轮过滤弹层应正常打开');

        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('搜索结果屏蔽词'), findsNothing,
            reason: '第 ${i + 1} 轮取消后弹层应关闭');

        await expectOverflowMenuOpen(tester);
        expect(tester.takeException(), isNull,
            reason: '第 ${i + 1} 轮 ⋮ 菜单不应触发红屏断言');

        // 关菜单（点按菜单外区域，对齐设备「点遮罩关闭」路径）
        await closeOverflowMenu(tester);
      }
      expect(tester.takeException(), isNull, reason: '三轮后页面不应有异常');
    });
  });
}
