// 发现列表「加载上一页」widget 测试（批39）
//
// 对齐原版 ExploreShowActivity：
// - page > 1 才显示顶部条；
// - 列表在顶部继续下拉（overscroll 后松手）触发 explore(oldPage - 1)；
// - 新页 prepend 到表头，首可见项 + offset 锚点保持视觉位置；
// - 失败时顶部条内联重试；
// - page = 1 不触发（下拉刷新保持原行为）；
// - [批39 审查回修] 请求在途滚动按响应时刻锚点恢复、空页同样补偿、
//   顶栏刷新入口（任何页回到第 1 页）、刷新被忽略时提示。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_show_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/explore_show_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  const testSource = BookSource(
    bookSourceUrl: 'http://source.com',
    bookSourceName: '测试书源',
  );

  // 规则支持页码：顶栏展示「第 N 页」，用于校验页号同步
  const pagedArgs = ExploreShowArgs(
    source: testSource,
    categoryName: '推荐榜',
    categoryUrl: 'http://source.com/rank?page={{page}}',
  );

  const prependedBook = SearchBook(
    bookUrl: 'http://book.com/0',
    name: '书籍0',
    author: '作者0',
  );

  /// 生成 [count] 本书（从 [start] 起），用于让列表具备可滚动高度
  /// （内容不足一屏时锚点无法通过滚动保持，属于物理约束）
  List<SearchBook> bookRange(int start, [int count = 10]) => List.generate(
        count,
        (i) => SearchBook(
          bookUrl: 'http://book.com/${start + i}',
          name: '书籍${start + i}',
          author: '作者${start + i}',
        ),
      );

  List<SearchBook> booksOfPage(int page) => bookRange(page * 10);

  /// 第 1 页（10 本，含锚点书）
  List<SearchBook> pageOneBooks() => bookRange(1);

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
  });

  Widget host() => ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: ExploreShowScreen(args: pagedArgs)),
      );

  ExploreShowState stateOf(WidgetTester tester) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExploreShowScreen)),
    );
    return container.read(exploreShowNotifierProvider(pagedArgs));
  }

  ExploreShowNotifier notifierOf(WidgetTester tester) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExploreShowScreen)),
    );
    return container.read(exploreShowNotifierProvider(pagedArgs).notifier);
  }

  testWidgets('page=2 顶部下拉加载 page1：prepend、页号同步、锚点不跳',
      (tester) async {
    var page1Calls = 0;
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((invocation) async {
      final page = invocation.positionalArguments[2] as int;
      if (page == 1) {
        page1Calls++;
        // 第二次请求第 1 页：榜单变化，多出一本新书（prepend 生效）
        return page1Calls == 1
            ? pageOneBooks()
            : [prependedBook, ...pageOneBooks()];
      }
      return booksOfPage(page);
    });

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('第 1 页'), findsOneWidget);
    // page = 1 不显示顶部「加载上一页」条
    expect(find.text('下拉加载上一页'), findsNothing);
    expect(find.text('书籍1'), findsOneWidget);

    // 加载第 2 页（模拟已下滑到底部后返回顶部）
    await notifierOf(tester).loadMore();
    await tester.pumpAndSettle();
    expect(find.text('第 2 页'), findsOneWidget);
    expect(find.text('下拉加载上一页'), findsOneWidget);

    final anchorFinder = find.text('书籍1');
    final beforeTop = tester.getTopLeft(anchorFinder).dy;

    // 在顶部继续下拉（超过触发阈值）后松手
    await tester.drag(anchorFinder, const Offset(0, 120));
    await tester.pumpAndSettle();

    // 页号同步回第 1 页，新页 prepend 到表头
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('书籍0'), findsOneWidget);
    expect(page1Calls, equals(2));
    // 顶部条随 page=1 隐藏
    expect(find.text('下拉加载上一页'), findsNothing);
    // 锚点保持：原首可见书仍停留在原视觉位置（允许亚像素误差）
    final afterTop = tester.getTopLeft(anchorFinder).dy;
    expect((afterTop - beforeTop).abs(), lessThan(2.0));
    // 游标不回退：仍可继续向下加载
    expect(stateOf(tester).page, equals(3));
    expect(stateOf(tester).hasMore, isTrue);
  });

  testWidgets('page=1 顶部下拉不触发加载上一页', (tester) async {
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((_) async => pageOneBooks());

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    clearInteractions(mockApi);

    // 40px 未达到下拉刷新阈值，也不应触发上一页
    await tester.drag(find.text('书籍1'), const Offset(0, 40));
    await tester.pumpAndSettle();

    expect(stateOf(tester).displayPage, equals(1));
    expect(stateOf(tester).isLoadingPrevious, isFalse);
    verifyNever(() => mockApi.exploreFetchBooks(any(), any(), any()));
  });

  testWidgets('加载上一页失败：顶部条内联错误，点击重试成功', (tester) async {
    var failPrevious = true;
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((invocation) async {
      final page = invocation.positionalArguments[2] as int;
      if (page == 1) {
        if (failPrevious) throw Exception('上一页网络错误');
        return [prependedBook, ...pageOneBooks()];
      }
      return booksOfPage(page);
    });

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    // 首屏失败（page=1 抛错）→ 先正常恢复首屏
    failPrevious = false;
    await notifierOf(tester).retry();
    await tester.pumpAndSettle();
    expect(find.text('第 1 页'), findsOneWidget);

    await notifierOf(tester).loadMore();
    await tester.pumpAndSettle();
    expect(find.text('第 2 页'), findsOneWidget);

    // 再次开启失败，顶部下拉触发上一页
    failPrevious = true;
    await tester.drag(find.text('书籍1'), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(find.text('上一页加载失败，点击重试'), findsOneWidget);
    // 失败不改写页号与列表
    expect(find.text('第 2 页'), findsOneWidget);
    expect(stateOf(tester).displayPage, equals(2));
    expect(stateOf(tester).previousError, contains('上一页网络错误'));

    // 重试成功
    failPrevious = false;
    await tester.tap(find.text('上一页加载失败，点击重试'));
    await tester.pumpAndSettle();

    expect(find.text('上一页加载失败，点击重试'), findsNothing);
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('书籍0'), findsOneWidget);
    expect(stateOf(tester).previousError, isNull);
  });

  // ─── [批39 审查回修] 在途滚动 / 空页补偿 / 顶栏刷新 / 刷新被忽略提示 ─────

  testWidgets('请求在途滚动：锚点按响应时刻的视口恢复（不被拉回旧位置）',
      (tester) async {
    final previousGate = Completer<List<SearchBook>>();
    var page1Calls = 0;
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((invocation) async {
      final page = invocation.positionalArguments[2] as int;
      if (page == 1) {
        page1Calls++;
        // 首屏第 1 页立即返回；之后的第 1 页请求（加载上一页）挂起
        if (page1Calls == 1) return pageOneBooks();
        return previousGate.future;
      }
      return booksOfPage(page);
    });

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await notifierOf(tester).loadMore();
    await tester.pumpAndSettle();
    expect(find.text('第 2 页'), findsOneWidget);

    // 顶部下拉触发上一页（请求挂起；顶部条转圈动画常驻 → 只能 pump）
    await tester.drag(find.text('书籍1'), const Offset(0, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(stateOf(tester).isLoadingPrevious, isTrue);

    // 在途期间继续向下滚动（用户没有停在触发位置）
    await tester.drag(find.text('书籍2'), const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    final beforeDy = tester.getTopLeft(find.text('书籍3')).dy;

    // 响应回来：旧实现用「请求前」的锚点，会把视口拉回触发时的位置
    previousGate.complete([prependedBook, ...pageOneBooks()]);
    await tester.pumpAndSettle();

    expect(stateOf(tester).books.first.name, equals('书籍0'));
    final afterDy = tester.getTopLeft(find.text('书籍3')).dy;
    expect(
      (afterDy - beforeDy).abs(),
      lessThan(2.0),
      reason: '锚点必须按响应时刻的首可见项采集（在途滚动的位移不得被抹掉）',
    );
  });

  testWidgets('上一页空页：列表不增长也要按锚点补偿顶部条高度变化',
      (tester) async {
    final previousGate = Completer<List<SearchBook>>();
    var page1Calls = 0;
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((invocation) async {
      final page = invocation.positionalArguments[2] as int;
      if (page == 1) {
        page1Calls++;
        // 首屏有数据；回退时的第 1 页挂起，随后返回空页
        if (page1Calls == 1) return pageOneBooks();
        return previousGate.future;
      }
      return booksOfPage(page);
    });

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await notifierOf(tester).loadMore();
    await tester.pumpAndSettle();
    expect(find.text('下拉加载上一页'), findsOneWidget);

    // 触发上一页（挂起），在途期间向下滚动，避免锚点被夹在顶部边界
    await tester.drag(find.text('书籍1'), const Offset(0, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(stateOf(tester).isLoadingPrevious, isTrue);
    await tester.drag(find.text('书籍2'), const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    final beforeDy = tester.getTopLeft(find.text('书籍3')).dy;

    // 第 1 页返回空（loadPreviousPage 成功但无新书）
    previousGate.complete(<SearchBook>[]);
    await tester.pumpAndSettle();

    expect(stateOf(tester).displayPage, equals(1));
    expect(find.text('书籍3'), findsOneWidget);
    // 顶部提示条消失（高度变化）后，锚点书仍停在原视觉位置
    final afterDy = tester.getTopLeft(find.text('书籍3')).dy;
    expect(
      (afterDy - beforeDy).abs(),
      lessThan(2.0),
      reason: '空页/重复页也要补偿（page=1 后顶部提示条不再占位）',
    );
  });

  testWidgets('顶栏刷新：page>1 也能回到第 1 页重新加载', (tester) async {
    var refreshed = false;
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((invocation) async {
      final page = invocation.positionalArguments[2] as int;
      if (page == 1) {
        return refreshed
            ? bookRange(100)
            : pageOneBooks();
      }
      return booksOfPage(page);
    });

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await notifierOf(tester).loadMore();
    await tester.pumpAndSettle();
    expect(find.text('第 2 页'), findsOneWidget);

    refreshed = true;
    await tester.tap(find.byKey(const ValueKey('explore-refresh-action')));
    await tester.pumpAndSettle();

    // 回到第 1 页并按新结果重建列表
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('书籍100'), findsOneWidget);
    expect(find.text('书籍1'), findsNothing);
    expect(stateOf(tester).displayPage, equals(1));
    expect(stateOf(tester).page, equals(2));
  });

  testWidgets('刷新被忽略（加载在途）时给出提示', (tester) async {
    final gate = Completer<List<SearchBook>>();
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((invocation) async {
      final page = invocation.positionalArguments[2] as int;
      if (page == 2) return gate.future;
      return pageOneBooks();
    });

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 加载更多挂起中 → 刷新与加载互斥
    final more = notifierOf(tester).loadMore();
    await tester.pump();
    expect(stateOf(tester).isLoading, isTrue);

    await tester.tap(find.byKey(const ValueKey('explore-refresh-action')));
    await tester.pump();

    expect(find.text('正在加载，请稍候再刷新'), findsOneWidget);
    // 列表未被刷新清空
    expect(find.text('书籍1'), findsOneWidget);

    gate.complete(booksOfPage(2));
    await more;
    await tester.pumpAndSettle();
    expect(find.text('第 2 页'), findsOneWidget);
  });
}
