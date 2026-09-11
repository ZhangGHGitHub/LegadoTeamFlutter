import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/change_source_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);

    when(() => mockApi.getConfig(any())).thenAnswer((_) async => '');
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    when(
      () => mockApi.updateSearchBookScore(any(), any()),
    ).thenAnswer((_) async {});
    when(() => mockApi.deleteSearchBook(any())).thenAnswer((_) async {});
    when(() => mockApi.disableBookSource(any())).thenAnswer((_) async {});
    when(
      () => mockApi.switchSource(any(), any(), any()),
    ).thenAnswer((_) async => '{"bookUrl":"https://b.com/book"}');
  });

  Map<String, dynamic> rawMatch({
    required String sourceUrl,
    required String sourceName,
    required String bookUrl,
    int bookScore = 0,
  }) => {
    'source_url': sourceUrl,
    'source_name': sourceName,
    'book_url': bookUrl,
    'book_name': '斗破苍穹',
    'author': '天蚕土豆',
    'book_score': bookScore,
  };

  /// T6 流式批次（契约 §2.4：matches 全量快照 + x/y 进度）
  Map<String, dynamic> makeBatch({
    required List<Map<String, dynamic>> matches,
    int finished = 1,
    int total = 1,
  }) => {
    'source_index': 0,
    'source_url': '',
    'source_name': '',
    'error': null,
    'finished_count': finished,
    'total_count': total,
    'is_last': true,
    'matches': matches,
  };

  /// stub searchSourceStream（named 参数全 any，匹配 notifier 的实际调用）
  void stubSearchStream(Stream<Map<String, dynamic>> stream) {
    when(
      () => mockApi.searchSourceStream(
        any(),
        any(),
        sourceUrls: any(named: 'sourceUrls'),
        loadInfo: any(named: 'loadInfo'),
        loadToc: any(named: 'loadToc'),
        loadWordCount: any(named: 'loadWordCount'),
        forceRefresh: any(named: 'forceRefresh'),
      ),
    ).thenAnswer((_) => stream);
  }

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  /// [A2 形态对齐] 将换源页作为真实 push 路由推入（home → 换源），
  /// 使 Navigator.pop 有可出栈的路由，用于验证「点遮罩 / 下滑关闭」
  Future<void> pumpChangeSourceAsRoute(
    WidgetTester tester, {
    String currentSourceUrl = 'https://a.com',
  }) async {
    stubSearchStream(
      Stream.value(
        makeBatch(
          matches: [
            rawMatch(
              sourceUrl: 'https://a.com',
              sourceName: 'A源',
              bookUrl: 'https://a.com/book',
            ),
            rawMatch(
              sourceUrl: 'https://b.com',
              sourceName: 'B源',
              bookUrl: 'https://b.com/book',
            ),
          ],
          finished: 2,
          total: 2,
        ),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          initialRoute: '/home',
          onGenerateRoute: (settings) {
            if (settings.name == '/home') {
              return MaterialPageRoute<void>(
                builder: (_) => const Text('HOME_PAGE'),
              );
            }
            return MaterialPageRoute<void>(
              builder: (_) => ChangeSourceScreen(
                bookName: '斗破苍穹',
                author: '天蚕土豆',
                currentSourceUrl: currentSourceUrl,
              ),
            );
          },
        ),
      ),
    );
    final navState = tester.state<NavigatorState>(find.byType(Navigator));
    navState.pushNamed('/change_source');
    await tester.pumpAndSettle();
  }

  Future<void> pumpChangeSource(
    WidgetTester tester, {
    String currentSourceUrl = 'https://a.com',
  }) async {
    stubSearchStream(
      Stream.value(
        makeBatch(
          matches: [
            rawMatch(
              sourceUrl: 'https://a.com',
              sourceName: 'A源',
              bookUrl: 'https://a.com/book',
            ),
            rawMatch(
              sourceUrl: 'https://b.com',
              sourceName: 'B源',
              bookUrl: 'https://b.com/book',
            ),
          ],
          finished: 2,
          total: 2,
        ),
      ),
    );

    await tester.pumpWidget(
      wrap(
        ChangeSourceScreen(
          bookName: '斗破苍穹',
          author: '天蚕土豆',
          currentSourceUrl: currentSourceUrl,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ChangeSourceScreen', () {
    // [A2 形态对齐] 路由承载弹层：换源路由须为非不透明路由（底部弹层）
    test('generateRoute 换源路由为非不透明底部弹层路由', () {
      final route = AppRoutes.generateRoute(
        const RouteSettings(name: AppRoutes.changeSource),
      );
      // 非不透明（opaque: false）→ 前页保持可见，由屏障压暗
      expect(route, isA<PageRoute>());
      expect((route as PageRoute).opaque, isFalse);
    });

    test('generateRoute 其余路由仍为普通整页路由', () {
      final route = AppRoutes.generateRoute(
        const RouteSettings(name: AppRoutes.bookInfo),
      ) as PageRoute;
      expect(route.opaque, isTrue);
    });

    testWidgets('顶栏显示书名 title 与作者 subtitle', (tester) async {
      await pumpChangeSource(tester);

      expect(find.text('斗破苍穹'), findsOneWidget);
      expect(find.text('天蚕土豆'), findsOneWidget);
      expect(find.textContaining('换源 -'), findsNothing);
    });

    testWidgets('点按赞调用 updateSearchBookScore(+1)', (tester) async {
      await pumpChangeSource(tester);

      await tester.tap(find.byTooltip('赞').first);
      await tester.pumpAndSettle();

      verify(
        () => mockApi.updateSearchBookScore('https://a.com/book', 1),
      ).called(1);
    });

    testWidgets('长按显示五项操作菜单', (tester) async {
      await pumpChangeSource(tester);

      await tester.longPress(find.text('B源'));
      await tester.pumpAndSettle();

      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('置底'), findsOneWidget);
      expect(find.text('编辑书源'), findsOneWidget);
      expect(find.text('禁用书源'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('长按禁用书源调用 disableBookSource', (tester) async {
      await pumpChangeSource(tester);

      await tester.longPress(find.text('B源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('禁用书源'));
      await tester.pumpAndSettle();

      verify(() => mockApi.disableBookSource('https://b.com')).called(1);
      expect(find.text('B源'), findsNothing);
    });

    testWidgets('底栏显示当前源名且滚顶/滚底按钮存在', (tester) async {
      await pumpChangeSource(tester);

      expect(find.text('A源'), findsWidgets);
      expect(find.byTooltip('滚到顶部'), findsOneWidget);
      expect(find.byTooltip('滚到底部'), findsOneWidget);
    });

    testWidgets('[A2] 底部弹层形态：把手 + 面板位于底部 85% 区域', (tester) async {
      await pumpChangeSource(tester);

      // 把手：32×4 圆角条
      final handle = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.constraints ==
                const BoxConstraints.tightFor(width: 32, height: 4),
      );
      expect(handle, findsOneWidget);

      // 面板（拖拽区 GestureDetector）贴底：顶边 ≈ 屏高 15%、占满宽度
      final panel = find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onVerticalDragStart != null,
      );
      expect(panel, findsOneWidget);
      final rect = tester.getRect(panel);
      expect(
        rect.top,
        closeTo(MediaQuery.sizeOf(tester.element(panel)).height * 0.15, 1),
      );
      expect(
        rect.width,
        closeTo(MediaQuery.sizeOf(tester.element(panel)).width, 1),
      );

      // 面板内仍为既有功能布局（顶栏标题 + 列表）
      expect(find.text('斗破苍穹'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('[A2] 点遮罩关闭弹层（pop 路由，回到前页）', (tester) async {
      await pumpChangeSourceAsRoute(tester);
      expect(find.text('A源'), findsWidgets);

      // 遮罩区 = 屏幕顶部 15%（面板占 85%），点按顶部区域
      await tester.tapAt(const Offset(400, 30));
      await tester.pumpAndSettle();

      expect(find.text('HOME_PAGE'), findsOneWidget);
      expect(find.text('A源'), findsNothing);
    });

    testWidgets('[A2] 下滑把手超阈值关闭弹层', (tester) async {
      await pumpChangeSourceAsRoute(tester);
      expect(find.text('A源'), findsWidgets);

      // 面板拖拽区（带 onVerticalDragStart 的 GestureDetector）
      final panel = find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onVerticalDragStart != null,
      );
      expect(panel, findsOneWidget);
      final rect = tester.getRect(panel);
      // 从把手/顶栏区（非列表滚动区）下滑 400px > 阈值 160px
      await tester.dragFrom(
        Offset(rect.center.dx, rect.top + 30),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();

      expect(find.text('HOME_PAGE'), findsOneWidget);
      expect(find.text('A源'), findsNothing);
    });

    testWidgets('[A2] 下滑未达阈值回弹不关闭', (tester) async {
      await pumpChangeSourceAsRoute(tester);
      expect(find.text('A源'), findsWidgets);

      final panel = find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onVerticalDragStart != null,
      );
      final rect = tester.getRect(panel);
      await tester.dragFrom(
        Offset(rect.center.dx, rect.top + 30),
        const Offset(0, 60),
      );
      await tester.pumpAndSettle();

      // 未达阈值：仍停留在换源弹层，回弹回位
      expect(find.text('HOME_PAGE'), findsNothing);
      expect(find.text('A源'), findsWidgets);
    });

    testWidgets('底栏滚顶按钮可点击', (tester) async {
      tester.view.physicalSize = const Size(400, 320);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      stubSearchStream(
        Stream.value(
          makeBatch(
            matches: List.generate(
              30,
              (i) => rawMatch(
                sourceUrl: 'https://src$i.com',
                sourceName: '源$i',
                bookUrl: 'https://src$i.com/book',
              ),
            ),
            finished: 30,
            total: 30,
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          const ChangeSourceScreen(
            bookName: '斗破苍穹',
            author: '天蚕土豆',
            currentSourceUrl: 'https://src0.com',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final listView = tester.widget<ListView>(find.byType(ListView));
      final controller = listView.controller;
      expect(controller, isNotNull);
      expect(controller!.position.maxScrollExtent, greaterThan(0));

      await tester.tap(find.byTooltip('滚到底部'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.offset, greaterThan(0));

      await tester.tap(find.byTooltip('滚到顶部'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.offset, 0);
    });
  });
}
