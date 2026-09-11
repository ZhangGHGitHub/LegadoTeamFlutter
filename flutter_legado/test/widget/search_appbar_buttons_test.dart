// [A1 形态对齐 | full-stack-engineer + UI] 搜索页顶栏三钮 + 结果过滤回归测试
//
// 覆盖：
// 1. 顶栏三钮（书源管理 / 搜索范围 / 搜索结果过滤）+ ⋮ 菜单「更多选项」均在位；
// 2. 结果过滤关闭态：按钮 tooltip 为「搜索结果过滤」，未过滤结果全量展示；
// 3. 结果过滤开启态（config searchResultFilter 非空）：命中屏蔽词的结果被
//    展示层过滤隐藏，按钮 tooltip 变为「搜索结果过滤（已开启）」；
// 4. ⋮ 菜单补齐「搜索结果过滤」项（原版六项不丢能力）。
import 'dart:async';

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

  List<Map<String, dynamic>> makeBooks(List<String> names) =>
      names
          .map(
              (n) => {
                    'origin': 'https://a.com',
                    'originName': '笔趣阁',
                    'name': n,
                    'author': '作者',
                    'bookUrl': 'https://a.com/b/$n',
                  })
          .toList();

  group('搜索页顶栏三钮（A1 形态对齐）', () {
    testWidgets('顶栏三钮 + ⋮ 菜单均在位', (tester) async {
      final events = StreamController<Map<String, dynamic>>();
      // [A1 形态对齐] searchMultiStream 契约含 page 参数（批次B G-B-01 翻页），
      // mock 须显式匹配 page，否则 mocktail 返回 null → 搜索报错、结果不落地
      when(() => mockApi.searchMultiStream(
              any(),
              sourceUrls: any(named: 'sourceUrls'),
              page: any(named: 'page')))
          .thenAnswer((_) => events.stream);

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pump();

      // 三钮 tooltip 均在顶栏
      expect(find.byTooltip('书源管理'), findsOneWidget);
      expect(find.byTooltip('搜索范围'), findsOneWidget);
      expect(find.byTooltip('搜索结果过滤'), findsOneWidget);
      // ⋮ 菜单保留
      expect(find.byTooltip('更多选项'), findsOneWidget);

      events.close();
    });

    testWidgets('过滤关闭态：命中词结果全量展示，按钮为常规态', (tester) async {
      final events = StreamController<Map<String, dynamic>>();
      when(() => mockApi.searchMultiStream(
              any(),
              sourceUrls: any(named: 'sourceUrls'),
              page: any(named: 'page')))
          .thenAnswer((_) => events.stream);

      await tester.pumpWidget(wrap(SearchScreen(initialQuery: 'abc')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      events.add(makeBatch(makeBooks(['遮光书 1', '明书 2'])));
      await tester.pump(const Duration(milliseconds: 400));

      // 过滤未开启（config 返回 null）→ 两本都展示
      expect(find.text('遮光书 1'), findsOneWidget);
      expect(find.text('明书 2'), findsOneWidget);
      // 按钮常规态 tooltip
      expect(find.byTooltip('搜索结果过滤'), findsOneWidget);

      events.close();
    });

    testWidgets('过滤开启态：命中屏蔽词被隐藏，按钮为已开启态', (tester) async {
      // 搜索结果过滤屏蔽词（对齐原版 PreferKey.searchResultFilter）
      when(() => mockApi.getConfig('searchResultFilter'))
          .thenAnswer((_) async => '遮光');
      final events = StreamController<Map<String, dynamic>>();
      when(() => mockApi.searchMultiStream(
              any(),
              sourceUrls: any(named: 'sourceUrls'),
              page: any(named: 'page')))
          .thenAnswer((_) => events.stream);

      await tester.pumpWidget(wrap(SearchScreen(initialQuery: 'abc')));
      // 等待 initState 的 getConfig 异步恢复过滤词
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      events.add(makeBatch(makeBooks(['遮光书 1', '明书 2'])));
      await tester.pump(const Duration(milliseconds: 400));

      // 命中「遮光」的《遮光书 1》被过滤隐藏；《明书 2》保留
      expect(find.text('遮光书 1'), findsNothing);
      expect(find.text('明书 2'), findsOneWidget);
      // 按钮进入「已开启」态 tooltip
      expect(find.byTooltip('搜索结果过滤（已开启）'), findsOneWidget);

      events.close();
    });

    testWidgets('⋮ 菜单补齐「搜索结果过滤」项', (tester) async {
      final events = StreamController<Map<String, dynamic>>();
      when(() => mockApi.searchMultiStream(
              any(),
              sourceUrls: any(named: 'sourceUrls'),
              page: any(named: 'page')))
          .thenAnswer((_) => events.stream);

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pump();

      // 打开 ⋮ 菜单
      await tester.tap(find.byTooltip('更多选项'));
      await tester.pumpAndSettle();
      expect(find.text('搜索结果过滤'), findsOneWidget);
      // 原版六项（静态）仍在
      expect(find.text('精准搜索'), findsOneWidget);
      expect(find.text('标识读过的书籍'), findsOneWidget);
      expect(find.text('书源管理'), findsOneWidget);
      expect(find.text('分组或书源'), findsOneWidget);
      expect(find.text('日志'), findsOneWidget);

      events.close();
    });
  });
}
