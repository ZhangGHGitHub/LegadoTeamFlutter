// 发现页展开区「实机路径等价」回归测试
//
// [P1 缺陷修复 | full-stack-engineer + UI + QA]
// 真机（MuMu 720x1280@320dpi → 360dp 宽）现象：展开书源后展开区恒为零高
// （SizeTransition 实测 8px，仅 top padding；3 列 chips 不可见），而 C8 测试
// 只断言 chip 宽度/顶边对齐、从不断言高度，故全绿却与真机不一致。
//
// 本测试走真实装配路径：真实 exploreNotifierProvider（Riverpod Notifier）+
// bookApiProvider 覆写为 mock（mock 网络，不经 Rust FFI）；源数据为 2 个
// 无 style 的 url 分类（对齐 kaixin7days 真机数据 玄幻/都市）。
// 断言展开区「实际渲染高度非零」——即 chips 真的占空间，而非仅存在于 widget 树。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  // 对齐真机 kaixin7days：2 个无 style 的 url 分类（_forceThreeColumns 后
  // 各占 1/3 → 3 列 chips）
  final kaixinSource = BookSource(
    bookSourceUrl: 'https://www.kaixin7days.com',
    bookSourceName: '开心7天',
    bookSourceGroup: '默认分组',
    exploreUrl:
        '玄幻::https://www.kaixin7days.com/x\n都市::https://www.kaixin7days.com/d',
  );

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    // 显式 ProviderContainer：既驱动 UI（UncontrolledProviderScope），
    // 又可在测试体读取 exploreNotifierProvider 状态断言空 type 归一化。
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => [kaixinSource]);
    when(
      () => mockApi.exploreParseUrl(any(), sourceJson: any(named: 'sourceJson')),
    ).thenAnswer(
      (_) async => [
        // [真机 FFI 形态等价] 真机 Rust 纯文本 :: 解析返回 type=""（空串），
        // 而非 'url'。此处忠实复现该形态，使本测试成为真机回归守卫：
        // 缺 explore_notifier 的空 type→'url' 归一化时，3 列/分节判定全部
        // 落空 → chips 退化通栏，本测试应失败。
        ExploreCategory(
          title: '玄幻',
          url: 'https://www.kaixin7days.com/x',
          type: '',
        ),
        ExploreCategory(
          title: '都市',
          url: 'https://www.kaixin7days.com/d',
          type: '',
        ),
      ],
    );
    when(
      () => mockApi.exploreFetchBooks(any(), any(), any()),
    ).thenAnswer(
      (_) async => const [
        SearchBook(bookUrl: 'http://b/1', name: '书1', author: '作者1'),
      ],
    );
  });

  /// 真实装配：真实 exploreNotifierProvider（由 ExploreScreen 内 ref.watch 驱动）
  /// + bookApiProvider 覆写 mock（经显式 container）。不走 final-state 注入。
  Widget buildApp() {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        onGenerateRoute: AppRoutes.generateRoute,
        home: const ExploreScreen(),
      ),
    );
  }

  testWidgets(
    '展开区实高非零（3 列 chips 真实渲染，非零高）——真机路径等价',
    (tester) async {
      // 对齐真机 MuMu：720x1280@320dpi → 360dp 逻辑宽（手机单列
      // _buildSourceList 路径，isTablet=false）。数据为 2 个无 style 的
      // url 分类（无空 URL 分节标题头），正是真机 kaixin7days 形态。
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      expect(find.text('开心7天'), findsOneWidget);

      // 点源名行 → 触发 loadCategories（mock 网络）+ 300ms 展开动画
      await tester.tap(find.text('开心7天'));
      // 单次 pumpAndSettle：驱动展开动画至完成，同时冲刷 mock 异步
      // （与 C8 测试同一已验证路径）
      await tester.pumpAndSettle();

      // 两个 3 列 chips 都真实渲染
      expect(find.text('玄幻'), findsOneWidget);
      expect(find.text('都市'), findsOneWidget);

      // chips 的实际渲染高度（取 chip 的 InkWell 容器）应非零（≥ minHeight 34）
      final xhBox = tester
          .getRect(find.ancestor(of: find.text('玄幻'), matching: find.byType(InkWell)));
      final dsBox = tester
          .getRect(find.ancestor(of: find.text('都市'), matching: find.byType(InkWell)));
      expect(xhBox.height, greaterThan(0), reason: 'chips 应真实占高，而非零高');
      expect(dsBox.height, greaterThan(0), reason: 'chips 应真实占高，而非零高');

      // 展开区（SizeTransition）实高应 > 仅 top padding 的 8px（含 chips 行高）
      final stFinder =
          find.ancestor(of: find.text('玄幻'), matching: find.byType(SizeTransition));
      expect(stFinder, findsOneWidget, reason: 'chips 应位于展开区 SizeTransition 内');
      final st = stFinder.evaluate().first.renderObject as RenderBox;
      expect(st.size.height, greaterThan(8),
          reason: '展开区实高应含 chips 行高，而非仅 8px top padding');

      // [真机回归守卫 | 数据层] mock 以真机 FFI 形态返回空 type，
      // explore_notifier 必须把空 type 归一化为 'url'（否则 3 列/分节
      // 判定落空，chips 退化通栏）。直接断言 Notifier 状态，像素无关、
      // 稳健：缺归一化时本断言必失败。
      final cached = container
          .read(exploreNotifierProvider)
          .categoriesFor(kaixinSource.bookSourceUrl);
      expect(cached, isNotNull, reason: '分类应已缓存');
      final types = cached!.map((c) => c.type).toList();
      expect(types, everyElement(equals('url')),
          reason: '空 type 应被归一化为 url（真机 FFI 空 type 补偿）');
    },
  );
}
