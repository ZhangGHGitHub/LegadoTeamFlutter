// 发现页 A4/C8 形态对齐 widget 测试
//
// [A4 形态对齐 | full-stack-engineer + UI]
// - A4（发现主页签）：行改卡片底（圆角 + onSurface 10% 填充）、
//   顶栏文件夹图标收编为 ⋮ 更多菜单（分组筛选能力无损）
// - C8（发现源二级展开区）：子项改 3 列 chips 分区网格
//   （空 URL 头项 → 通栏分节标题；非通栏 URL 项 → 固定 3 列；
//    通栏 URL 项（如排行榜，basis>=1）→ 保留全宽行；点击链路不变）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  const cellStyle = FlexChildStyle(
    layoutFlexGrow: 1,
    layoutFlexBasisPercent: 1 / 3,
  );
  const wideStyle = FlexChildStyle(
    layoutFlexGrow: 1,
    layoutFlexBasisPercent: 1,
  );

  final c8Source = BookSource(
    bookSourceUrl: 'https://c8.test',
    bookSourceName: '发现源C8',
    bookSourceGroup: '默认分组',
    exploreUrl: '''[
      {"title":"排行榜","style":{"layout_flexBasisPercent":1}},
      {"title":"巅峰榜","url":"https://c8.test/rank/dianfeng"},
      {"title":"出版榜","url":"https://c8.test/rank/chuban"},
      {"title":"完结榜","url":"https://c8.test/rank/wanjie"},
      {"title":"热门标签","style":{"layout_flexBasisPercent":1}},
      {"title":"玄幻","url":"https://c8.test/tag/xuanhuan"},
      {"title":"都市","url":"https://c8.test/tag/dushi"}
    ]''',
  );

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources())
        .thenAnswer((_) async => [c8Source]);
    when(() => mockApi.exploreParseUrl(any(), sourceJson: any(named: 'sourceJson')))
        .thenAnswer((_) async => [
          const ExploreCategory(
            title: '排行榜',
            style: wideStyle,
          ),
          const ExploreCategory(
            title: '巅峰榜',
            url: 'https://c8.test/rank/dianfeng',
            style: cellStyle,
          ),
          const ExploreCategory(
            title: '出版榜',
            url: 'https://c8.test/rank/chuban',
            style: cellStyle,
          ),
          const ExploreCategory(
            title: '完结榜',
            url: 'https://c8.test/rank/wanjie',
          ),
          const ExploreCategory(
            title: '热门标签',
            style: wideStyle,
          ),
          const ExploreCategory(
            title: '玄幻',
            url: 'https://c8.test/tag/xuanhuan',
          ),
          const ExploreCategory(
            title: '都市',
            url: 'https://c8.test/tag/dushi',
          ),
        ]);
    when(() => mockApi.exploreFetchBooks(any(), any(), any())).thenAnswer(
      (_) async => const [
        SearchBook(bookUrl: 'http://book.com/1', name: '书1', author: '作者1'),
      ],
    );
  });

  Widget buildApp() {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
      child: MaterialApp(
        onGenerateRoute: AppRoutes.generateRoute,
        home: const ExploreScreen(),
      ),
    );
  }

  /// 展开指定书源行（点源名行 → 加载分类 → 渲染 chips）
  Future<void> expandSource(WidgetTester tester, String sourceName) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text(sourceName));
    await tester.pumpAndSettle();
  }

  double chipWidth(WidgetTester tester, String title) => tester
      .getSize(find.ancestor(
            of: find.text(title),
            matching: find.byType(InkWell),
          ))
      .width;

  testWidgets('C8：展开区分节 3 列 chips 网格（分节标题通栏 + 非通栏 URL 3 列）',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await expandSource(tester, '发现源C8');

    // 分节标题（空 URL 头项）→ 通栏纯文本，不进 chips 网格
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('热门标签'), findsOneWidget);

    // 非通栏 URL 项（含无 style 默认 -1 的「完结榜」）→ 固定 3 列
    const expectedChipWidth = (400 - 32 - 12) / 3;
    for (final title in ['巅峰榜', '出版榜', '完结榜', '玄幻', '都市']) {
      expect(chipWidth(tester, title), closeTo(expectedChipWidth, 2),
          reason: '「$title」应为 3 列 chip（宽 ≈ ${expectedChipWidth.toStringAsFixed(1)}）');
    }

    // 分节标题通栏左对齐：标题左缘与 3 列 chips 首列左缘对齐（内容区左边）
    final firstChipLeft = tester
        .getTopLeft(find.ancestor(
          of: find.text('巅峰榜'),
          matching: find.byType(InkWell),
        ))
        .dx;
    expect(tester.getTopLeft(find.text('排行榜')).dx, closeTo(firstChipLeft, 1),
        reason: '分节标题应通栏左对齐，与 chips 网格左缘对齐');

    // 3 列同行：巅峰榜/出版榜/完结榜 顶边对齐
    final dyA = tester.getTopLeft(find.text('巅峰榜')).dy;
    final dyB = tester.getTopLeft(find.text('出版榜')).dy;
    final dyC = tester.getTopLeft(find.text('完结榜')).dy;
    expect(dyA, closeTo(dyB, 1));
    expect(dyA, closeTo(dyC, 1));
  });

  testWidgets('A4：顶栏 ⋮ 更多菜单收编分组筛选（文件夹图标已收编）',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await expandSource(tester, '发现源C8');

    // 顶栏仅 ⋮（原文件夹图标已收编为菜单内分组筛选）
    expect(find.byIcon(Symbols.more_vert_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.folder_copy_rounded), findsNothing);

    // 打开 ⋮ 菜单：「全部」+ 各分组齐全（顶栏副标题也是「全部」，故 ≥1），
    // 选择即分组筛选（收编后能力无损）
    await tester.tap(find.byIcon(Symbols.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('全部'), findsWidgets);
    expect(find.text('默认分组'), findsOneWidget);
    await tester.tap(find.text('默认分组'));
    await tester.pumpAndSettle();

    // 菜单关闭后顶栏副标题回显选中分组（分组筛选生效）
    expect(find.text('默认分组'), findsOneWidget);
  });

  testWidgets('A4：书源行卡片底（onSurface 10% 圆角容器）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await expandSource(tester, '发现源C8');

    final card = tester.widget<Container>(
      find.ancestor(
        of: find.text('发现源C8'),
        matching: find.byType(Container),
      ).last,
    );
    final deco = card.decoration! as BoxDecoration;
    expect(deco.borderRadius,
        const BorderRadius.all(Radius.circular(12)));
    // 卡片底色应为 onSurface 10% 填充（alpha ≈ 0.10，.a 为 0.0–1.0 比例）
    expect(deco.color!.a, closeTo(0.10, 0.01),
        reason: '卡片底色应为 onSurface 10% 填充，'
            '实际 alpha=${deco.color!.a}');
  });

  testWidgets('C8：chips 点击链路不变（点进发现书单页，参数正确）',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await expandSource(tester, '发现源C8');

    // 点 3 列 chips 中的「巅峰榜」→ push exploreShow（链路不变：
    // onCategoryTap → _openExploreShow → ExploreShowArgs(source, 分类, URL)）
    await tester.tap(find.text('巅峰榜'));
    await tester.pumpAndSettle();

    // 到达发现书单页（exploreShow）：页码控件 + 已抓取书籍渲染
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('书1'), findsOneWidget);

    // 分类参数正确回显（标题 = 分类名 - 书源名，对标原版 exploreName）
    expect(find.text('巅峰榜 - 发现源C8'), findsOneWidget);

    // 抓取 URL 即 chip 的分类 URL（点击链路参数不变；captureAny 捕获实参）
    final captured = verify(
      () => mockApi.exploreFetchBooks(captureAny(), captureAny(), captureAny()),
    ).captured;
    expect(captured, hasLength(3));
    expect(captured[1], 'https://c8.test/rank/dianfeng');
  });
}
