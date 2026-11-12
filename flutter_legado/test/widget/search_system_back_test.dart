// 搜索页系统返回键回归测试（2026-11-13，设备验收批22 P2）
//
// 缺陷现象：从书架进入全局搜索页后，连续两次系统返回键仍停留在搜索页，
// 只能点左上角返回按钮退出（证据 docs/materials_1113a/tmp_qb22_67.png）。
//
// 语义基线：
// - 搜索框聚焦时，第一次返回仅失焦不退出（模拟软键盘被系统返回键收起，
//   对齐原版 finish()/SearchActivity 行为）；
// - 失焦后再次返回必须真正退出页面；
// - 参考版 onBack 直达返回，无「先清空输入文本」语义，本页同样不新增。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';

import '../mocks/mocks.dart';

/// 宿主页：模拟书架等入口 push 搜索页，返回后可回到宿主页。
class _SearchHost extends StatelessWidget {
  const _SearchHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
          child: const Text('打开搜索页'),
        ),
      ),
    );
  }
}

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(
      () => mockApi.getSearchHistory(limit: any(named: 'limit')),
    ).thenAnswer((_) async => []);
    when(() => mockApi.addSearchKeyword(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.clearSearchHistory()).thenAnswer((_) async {});
    when(() => mockApi.cancelSearch()).thenAnswer((_) async {});
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.getEnabledBookSources()).thenAnswer((_) async => []);
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

  /// 进入搜索页（真实路由 push，便于断言返回后页面是否被 pop）。
  Future<void> openSearch(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const _SearchHost()));
    await tester.tap(find.text('打开搜索页'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
  }

  /// 搜索框当前是否持有焦点（SearchScreen 把私有 FocusNode 传给 SearchBar）。
  bool searchFieldFocused(WidgetTester tester) {
    final bars = tester.widgetList<SearchBar>(find.byType(SearchBar));
    return bars.any((bar) => bar.focusNode?.hasFocus ?? false);
  }

  /// 模拟一次 Android 系统返回键（flutter/navigation popRoute 通道）。
  Future<void> pressSystemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  /// 模拟软键盘升降（MediaQuery.viewInsets.bottom）。
  Future<void> setKeyboardVisible(WidgetTester tester, bool visible) async {
    tester.view.viewInsets = visible
        ? const FakeViewPadding(bottom: 300)
        : FakeViewPadding.zero;
    await tester.pumpAndSettle();
  }

  group('SearchScreen 系统返回键', () {
    testWidgets('聚焦态：第一次返回仅失焦不退出，第二次返回退出页面', (tester) async {
      await openSearch(tester);
      // 进入搜索页自动聚焦（对齐参考版：进入即可输入）
      expect(searchFieldFocused(tester), isTrue);

      // 第一次返回：只失焦，页面保持
      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(searchFieldFocused(tester), isFalse);

      // 第二次返回：必须真正退出页面（缺陷：修复前仍停留在搜索页）
      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsNothing);
      expect(find.text('打开搜索页'), findsOneWidget);
    });

    testWidgets('无焦点初始态：返回直接退出页面', (tester) async {
      await openSearch(tester);
      // 模拟进入页面时未获得焦点（如自动聚焦被外部交互打断）
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(searchFieldFocused(tester), isFalse);

      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsNothing);
      expect(find.text('打开搜索页'), findsOneWidget);
    });

    testWidgets('重新聚焦后：首返仍只失焦，不因标志位残留直接退出', (tester) async {
      await openSearch(tester);

      // 第一次返回消费失焦
      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(searchFieldFocused(tester), isFalse);

      // 用户重新点输入框继续输入 → 焦点恢复
      await tester.tap(find.byType(SearchBar));
      await tester.pumpAndSettle();
      expect(searchFieldFocused(tester), isTrue);

      // 再次返回：仍应先失焦而非直接退出
      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(searchFieldFocused(tester), isFalse);

      // 再按一次返回：退出
      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsNothing);
    });

    testWidgets('键盘被系统返回收起（首次返回被 IME 消费）：下一次返回直接退出', (tester) async {
      addTearDown(tester.view.reset);
      await openSearch(tester);
      expect(searchFieldFocused(tester), isTrue);

      // 自动聚焦后软键盘弹出
      await setKeyboardVisible(tester, true);

      // 第一次系统返回被 IME 消费：只收起键盘，Flutter 收不到 popRoute，
      // 焦点保持不变（与真机一致）。
      await setKeyboardVisible(tester, false);
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(searchFieldFocused(tester), isTrue);

      // 第二次返回送达 Flutter：必须直接退出页面
      //（缺陷：修复前只执行失焦，页面仍停留在搜索页）
      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsNothing);
      expect(find.text('打开搜索页'), findsOneWidget);
    });

    testWidgets('360dp 窄屏：两次返回语义与宽屏一致', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await openSearch(tester);
      expect(searchFieldFocused(tester), isTrue);

      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(searchFieldFocused(tester), isFalse);

      await pressSystemBack(tester);
      expect(find.byType(SearchScreen), findsNothing);
    });
  });
}
