// SearchScreen 滚顶行为回归测试（2026-08-24）
//
// 缺陷根因：旧「新批次到达时滚顶」条件在加载中任何长度变化都触发，
// 节流增量渲染每 150ms flush 一次 → animateTo(0) 反复执行，页面被强制拉回
// 最上方、无法滚动。修复后对齐原版 AdapterDataObserver.onItemRangeInserted
// 语义（仅 positionStart == 0 —— 新搜索重置重填时滚顶）：流式增量批次与
// 续页追加不触发；新关键词结果到达时 ListView 已随 results 清空而销毁重建，
// 天然从顶部开始。— Qoder UI
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/search/search_notifier.dart';
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

  /// 构造流式搜索批次（字段契约同 BookApi.searchMultiStream）
  Map<String, dynamic> makeBatch(List<Map<String, dynamic>> books,
          {bool isLast = false}) =>
      {
        'source_index': 0,
        'source_url': 'https://a.com',
        'source_name': '笔趣阁',
        'books': books,
        'error': null,
        'finished_count': 1,
        'total_count': 1,
        'is_last': isLast,
      };

  List<Map<String, dynamic>> makeBooks(int count, {String prefix = '书'}) =>
      List.generate(
          count,
          (i) => {
                'origin': 'https://a.com',
                'originName': '笔趣阁',
                'name': '$prefix ${i + 1}',
                'author': '作者$i',
                'bookUrl': 'https://a.com/b/$i',
              });

  /// 读取结果列表当前滚动偏移（逻辑像素）。
  /// 树中存在多个 Scrollable（如输入帮助层内部），取首个——即结果列表
  /// （diag6 实测：其 maxExtent ≈ 40 项 × 122px，与结果列表吻合）。
  double readPixels(WidgetTester tester) =>
      tester.stateList<ScrollableState>(find.byType(Scrollable)).first.position.pixels;

  /// 下滑直到滚动偏移达到 [target]：每次手势向上拖 200px，
  /// 实际滚动量由视口决定（实测约 130px/次），循环自校正，至多 60 次。
  Future<void> scrollDown(WidgetTester tester, double target) async {
    var guard = 0;
    while (readPixels(tester) < target && guard < 60) {
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 50));
      guard += 1;
    }
  }

  group('SearchScreen 滚顶行为（对齐原版 AdapterDataObserver）', () {
    testWidgets(
        '流式增量批次不拉回滚动位置（回归：强制回顶无法滚动）',
        (tester) async {
      final events = StreamController<Map<String, dynamic>>();
      when(() => mockApi.searchMultiStream(
              any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => events.stream);

      await tester.pumpWidget(wrap(SearchScreen(initialQuery: 'abc')));
      // microtask（resetForOpen + search）+ 首个节流 flush
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      events.add(makeBatch(makeBooks(40)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ListView), findsOneWidget);
      // 稳定排序保证到达序：'书 1' 是 item 0，必在可见区
      expect(find.text('书 1'), findsOneWidget);

      // 下滑到列表中部（偏移 > 800px，远离顶部）
      await scrollDown(tester, 800);
      final before = readPixels(tester);
      expect(before, greaterThan(800));

      // 第二批到达（模拟另一来源的结果）→ 触发又一次节流 flush
      events.add(makeBatch(makeBooks(40, prefix: '乙书')));
      await tester.pump(const Duration(milliseconds: 400));

      // 旧缺陷：该次 flush 会 animateTo(0) 把页面拉回顶部；
      // 修复后：增量批次不改变滚动偏移。
      expect(readPixels(tester), closeTo(before, 5.0));

      events.close();
    });

    testWidgets('新搜索仍滚顶（原版 positionStart==0 语义）', (tester) async {
      final c1 = StreamController<Map<String, dynamic>>();
      final c2 = StreamController<Map<String, dynamic>>();
      var first = true;
      when(() => mockApi.searchMultiStream(
              any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) {
        if (first) {
          first = false;
          return c1.stream;
        }
        return c2.stream;
      });

      await tester.pumpWidget(wrap(SearchScreen(initialQuery: 'abc')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      c1.add(makeBatch(makeBooks(40)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('书 1'), findsOneWidget);

      // 先下滑，再发起新搜索（不同关键词）
      await scrollDown(tester, 800);
      final before = readPixels(tester);
      expect(before, greaterThan(800));

      // 结束旧流：onDone 将 _searchSub 置 null。FakeAsync 下任何
      // StreamSubscription.cancel() 的 Future 都不随 pump 完成（dart:async
      // 与 FakeAsync 的系统性行为），会使 search() 内的 _cancelActiveSearch
      // 挂起；让旧流自然结束即可绕开 cancel 路径（生产环境无此限制）。
      c1.close();
      await tester.pump(const Duration(milliseconds: 400));

      unawaited(container.read(searchNotifierProvider.notifier).search('xyz'));
      await tester.pump();
      await tester.pump();
      // search() 同步清空 results → 旧列表销毁，显示加载态
      expect(find.byType(ListView), findsNothing);

      // 新关键词首批结果到达 → ListView 重建，必须从顶部开始
      c2.add(makeBatch(makeBooks(40, prefix: '新书')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byType(ListView), findsOneWidget);
      expect(readPixels(tester), closeTo(0.0, 5.0));
      expect(find.text('新书 1'), findsOneWidget);
      c1.close();
      c2.close();
    });
  });
}
