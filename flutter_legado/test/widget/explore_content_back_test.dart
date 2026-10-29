// 批36c 源内容模式返回键归属回归测试
//
// 缺陷（设备验收场景 6）：`HomeScreen` 根 PopScope 与 `ExploreScreen` 内内容
// 模式 PopScope 同属一个 ModalRoute，系统返回会依次通知两者（didPop=false），
// 内层无法消费本次返回 → 内容模式关闭的同时 Tab 被切回书架。
//
// 修法：把「内容模式返回 → 回源列表且不切 Tab」上移到
// `HomeScreen._handleBack`，发现页不再挂 PopScope。
//
// 覆盖：
// 1. 内容模式返回：停留发现并回源列表；再按返回切书架；
// 2. 源列表模式返回：直接切书架；
// 3. 内容模式手动切回源列表后返回：切书架。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_main_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/widgets/explore_source_content.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const source = BookSource(
    bookSourceUrl: 'https://a.test',
    bookSourceName: '发现源A',
    exploreUrl: '分类一::https://a.test/one',
  );

  const kindOne = ExploreCategory(title: '分类一', url: 'https://a.test/one');

  setUpAll(registerFallbacks);

  late MockRustApi mockApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => []);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => [source]);
    when(() => mockApi.getRssSources()).thenAnswer((_) async => []);
    // 首页页签数据源：阅读记录 + 每日时长
    when(() => mockApi.getReadRecords()).thenAnswer((_) async => []);
    when(() => mockApi.readRecordDailyList(any())).thenAnswer((_) async => []);
    when(
      () =>
          mockApi.exploreParseUrl(any(), sourceJson: any(named: 'sourceJson')),
    ).thenAnswer((_) async => [kindOne]);
    when(() => mockApi.exploreFetchBooks(any(), any(), any())).thenAnswer(
      (_) async => [
        const SearchBook(
          bookUrl: 'https://a.test/book/1',
          name: '分类一之书',
          author: '作者',
        ),
      ],
    );
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));

  /// 底栏切到发现 Tab（索引 2）
  Future<void> openExplore(WidgetTester tester) async {
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    expect(navBarIndex(tester), 2);
  }

  /// 顶栏「切换到源内容」进入内容模式
  Future<void> enterContentMode(WidgetTester tester) async {
    await tester.tap(find.byTooltip('切换到源内容'));
    await tester.pumpAndSettle();
    expect(find.byType(ExploreSourceContent), findsOneWidget);
    expect(find.byTooltip('返回源列表'), findsOneWidget);
  }

  testWidgets('内容模式按返回：停留发现并回源列表；再按返回切书架', (tester) async {
    await pumpHome(tester);
    await openExplore(tester);
    await enterContentMode(tester);

    // 第一次返回：内容模式 → 源列表，Tab 保持「发现」
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(navBarIndex(tester), 2);
    expect(find.byType(ExploreSourceContent), findsNothing);
    expect(find.byTooltip('切换到源内容'), findsOneWidget);
    expect(find.byTooltip('返回源列表'), findsNothing);
    expect(
      containerOf(tester).read(exploreMainNotifierProvider).showContent,
      isFalse,
    );

    // 第二次返回：源列表模式 → 原有逻辑切回书架
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(navBarIndex(tester), 1);
  });

  testWidgets('源列表模式按返回：直接切回书架', (tester) async {
    await pumpHome(tester);
    await openExplore(tester);
    expect(find.byTooltip('切换到源内容'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(navBarIndex(tester), 1);
  });

  testWidgets('内容模式手动切回源列表后再按返回：切回书架', (tester) async {
    await pumpHome(tester);
    await openExplore(tester);
    await enterContentMode(tester);

    // 顶栏「返回源列表」（用户显式切回）
    await tester.tap(find.byTooltip('返回源列表'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换到源内容'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(navBarIndex(tester), 1);
  });
}
