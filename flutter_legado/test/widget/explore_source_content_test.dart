// 发现页「源内容模式」widget 测试（批36）
//
// 参考版依据：ExploreMainRoute.kt（顶栏搜索/切回源列表/书源选择 + 分类 Tab）、
// ExploreSourceSelectSheet.kt（搜索/分组/布局列数）、ExploreMainViewModel.kt
// （exploreMainContent/exploreMainSourceUrl/exploreMainKind 恢复与回退）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_main_notifier.dart';
import 'package:flutter_legado/src/providers/explore/explore_main_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRustApi mockApi;

  const source = BookSource(
    bookSourceUrl: 'https://a.test',
    bookSourceName: '发现源A',
    bookSourceGroup: '分组一',
    exploreUrl: '分类一::https://a.test/one\n分类二::https://a.test/two',
  );

  const kindOne = ExploreCategory(title: '分类一', url: 'https://a.test/one');
  // 分类二为支持页码的规则（含 {{page}}）→ 源内容模式底栏应显示页码按钮
  const kindTwo = ExploreCategory(
    title: '分类二',
    url: 'https://a.test/two?page={{page}}',
  );

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => [source]);
    when(
      () =>
          mockApi.exploreParseUrl(any(), sourceJson: any(named: 'sourceJson')),
    ).thenAnswer((_) async => [kindOne, kindTwo]);
    when(() => mockApi.exploreFetchBooks(any(), any(), any())).thenAnswer((
      invocation,
    ) async {
      final url = invocation.positionalArguments[1] as String;
      final page = invocation.positionalArguments[2] as int;
      final name = url.contains('/two') ? '分类二之书' : '分类一之书';
      return [
        SearchBook(
          bookUrl: 'https://a.test/book/$url/$page',
          name: '$name 第$page页',
          author: '作者',
        ),
      ];
    });
  });

  Widget buildApp() {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
      child: const MaterialApp(home: ExploreScreen()),
    );
  }

  /// 读取当前 ProviderContainer（用于断言持久化状态）
  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(ExploreScreen)));

  testWidgets('顶栏切换到源内容模式：分类 Tab + 书单列表 + 落盘', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 源列表模式：顶栏「切换到源内容」入口存在
    expect(find.byTooltip('切换到源内容'), findsOneWidget);

    await tester.tap(find.byTooltip('切换到源内容'));
    await tester.pumpAndSettle();

    // 源内容模式：分类 Tab + 分类一书籍 + 切回源列表入口
    expect(find.text('分类一'), findsOneWidget);
    expect(find.text('分类二'), findsOneWidget);
    expect(find.text('分类一之书 第1页'), findsOneWidget);
    expect(find.byTooltip('返回源列表'), findsOneWidget);
    // 分类一规则不含页码 → 不显示页码按钮（对齐参考版 canJumpPage）
    expect(find.text('第 1 页'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(exploreMainContentKey), isTrue);
    expect(prefs.getString(exploreMainSourceUrlKey), source.bookSourceUrl);

    // 切回源列表（分类 chip 可能已缓存并挂在折叠区里，不以分类文案判定）
    await tester.tap(find.byTooltip('返回源列表'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换到源内容'), findsOneWidget);
    expect(find.byTooltip('返回源列表'), findsNothing);
    expect(find.text('分类一之书 第1页'), findsNothing);
    expect(prefs.getBool(exploreMainContentKey), isFalse);
  });

  testWidgets('重启恢复：exploreMainContent/exploreMainSourceUrl/exploreMainKind', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final kindTwoKey = exploreKindKey(kindTwo);
    SharedPreferences.setMockInitialValues({
      exploreMainContentKey: true,
      exploreMainSourceUrlKey: source.bookSourceUrl,
      exploreMainKindKey: encodeExploreKindSelections({
        source.bookSourceUrl: kindTwoKey,
      }),
    });

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 直接进入源内容模式，且恢复到「分类二」
    expect(find.byTooltip('返回源列表'), findsOneWidget);
    expect(find.text('分类二之书 第1页'), findsOneWidget);
    expect(find.text('分类一之书 第1页'), findsNothing);
    // 分类二规则含 {{page}} → 页码按钮出现
    expect(find.text('第 1 页'), findsOneWidget);
  });

  testWidgets('选中源被删除时回退源列表（不进入失效源内容）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      exploreMainContentKey: true,
      exploreMainSourceUrlKey: 'https://gone.test',
    });

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 源列表模式（源 A 仍在列）
    expect(find.text('发现源A'), findsOneWidget);
    expect(find.byTooltip('切换到源内容'), findsOneWidget);
    expect(find.byTooltip('返回源列表'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(exploreMainContentKey), isFalse);
  });

  testWidgets('书源选择 sheet：搜索/分组/布局列数，切网格后列表用网格渲染', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换到源内容'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('选择书源'));
    await tester.pumpAndSettle();

    // sheet 标题 + 布局控件 + 搜索框 + 分组筛选
    expect(find.text('选择书源'), findsWidgets);
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('网格'), findsOneWidget);
    expect(find.text('搜索书源（名称/地址）'), findsOneWidget);
    expect(find.text('分组一'), findsWidgets);

    await tester.tap(find.text('网格'));
    await tester.pumpAndSettle();

    final container = containerOf(tester);
    expect(container.read(exploreMainNotifierProvider).gridMode, isTrue);
    expect(find.text('3 列'), findsOneWidget);

    // 增加列数 → 落盘（竖屏键）
    await tester.tap(find.byTooltip('增加列数'));
    await tester.pumpAndSettle();
    expect(find.text('4 列'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(exploreLayoutGridPortraitKey), 4);

    // 关闭 sheet（点击遮罩）后内容列表使用网格渲染
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('分类选择 sheet 可切换当前分类', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换到源内容'));
    await tester.pumpAndSettle();

    expect(find.text('分类一之书 第1页'), findsOneWidget);

    await tester.tap(find.byTooltip('选择分类'));
    await tester.pumpAndSettle();
    expect(find.text('选择分类'), findsOneWidget);

    // 分类 Tab 与 sheet 列表各有一个「分类二」，点 sheet 中的列表项
    await tester.tap(find.text('分类二').last);
    await tester.pumpAndSettle();

    expect(find.text('分类二之书 第1页'), findsOneWidget);
    expect(find.text('分类一之书 第1页'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    final saved = parseExploreKindSelections(
      prefs.getString(exploreMainKindKey) ?? '',
    );
    expect(saved[source.bookSourceUrl], exploreKindKey(kindTwo));
  });
}
