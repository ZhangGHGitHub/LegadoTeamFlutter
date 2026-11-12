// 书架内搜索过滤 + 「搜索直达」开关行为回归
//
// 对齐参考版 BookshelfScreen.onSearchClick / onSearchLongClick：
// - 搜索直达开（默认）：点击 → 全局搜索页；长按 → 书架内过滤
// - 搜索直达关：点击 → 书架内过滤；长按 → 全局搜索页
// 过滤条输入即筛（书名/作者等），无匹配显示空态，清除后恢复。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/widgets/book_grid_item.dart';

import '../mocks/mocks.dart';

/// 记录 push 的路由名
class _RouteRecorder extends NavigatorObserver {
  final List<String?> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
    super.didPush(route, previousRoute);
  }
}

void main() {
  setUpAll(registerFallbacks);

  Future<void> pumpShelf(
    WidgetTester tester, {
    required MockRustApi api,
    Map<String, Object> prefs = const {},
    NavigatorObserver? observer,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    when(() => api.getBooks()).thenAnswer(
      (_) async => const [
        Book(bookUrl: 'u1', name: '书一', author: '作者甲'),
        Book(bookUrl: 'u2', name: '书二', author: '作者乙'),
      ],
    );
    when(() => api.getBookGroups()).thenAnswer((_) async => const []);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          navigatorObservers: observer == null ? const [] : [observer],
          routes: {
            AppRoutes.search: (_) => const Scaffold(body: Text('search-stub')),
          },
          home: const BookshelfScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final searchButton = find.byKey(const ValueKey('bookshelf_search_button'));
  final filterField = find.byKey(const ValueKey('bookshelf_filter_field'));
  final filterClear = find.byKey(const ValueKey('bookshelf_filter_clear'));

  /// 书名卡片（排除过滤输入框自身的 EditableText 命中）
  Finder shelfTitle(String name) =>
      find.descendant(of: find.byType(BookGridItem), matching: find.text(name));

  testWidgets('搜索直达开（默认）：点击进搜索页，长按进书架内过滤', (tester) async {
    final api = MockRustApi();
    final recorder = _RouteRecorder();
    await pumpShelf(tester, api: api, observer: recorder);

    expect(find.byTooltip('搜索'), findsOneWidget);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(recorder.pushed, contains(AppRoutes.search));
    expect(find.text('search-stub'), findsOneWidget);
    expect(filterField, findsNothing);
  });

  testWidgets('搜索直达开：长按进入书架内过滤', (tester) async {
    final api = MockRustApi();
    await pumpShelf(tester, api: api);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);
    expect(shelfTitle('书一'), findsOneWidget);
    expect(shelfTitle('书二'), findsOneWidget);
  });

  testWidgets('搜索直达关：点击进书架内过滤，长按进搜索页', (tester) async {
    final api = MockRustApi();
    final recorder = _RouteRecorder();
    await pumpShelf(
      tester,
      api: api,
      observer: recorder,
      prefs: {BookshelfSettings.keyBookshelfSearchActionDirectToSearch: false},
    );

    expect(find.byTooltip('书架内搜索'), findsOneWidget);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);
    expect(recorder.pushed, isNot(contains(AppRoutes.search)));

    // 再点搜索按钮 → 退出过滤（参考版同一入口切换）
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsNothing);
    // 退出过滤后长按 → 全局搜索页
    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(recorder.pushed, contains(AppRoutes.search));
  });

  testWidgets('过滤：书名/作者即筛、无匹配空态、清除恢复', (tester) async {
    final api = MockRustApi();
    await pumpShelf(tester, api: api);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);

    // 书名匹配
    await tester.enterText(filterField, '书二');
    await tester.pumpAndSettle();
    expect(shelfTitle('书二'), findsOneWidget);
    expect(shelfTitle('书一'), findsNothing);

    // 作者匹配
    await tester.enterText(filterField, '作者甲');
    await tester.pumpAndSettle();
    expect(shelfTitle('书一'), findsOneWidget);
    expect(shelfTitle('书二'), findsNothing);

    // 无匹配 → 空态（输入条保留，可继续修改）
    await tester.enterText(filterField, '不存在的书');
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配的书籍'), findsOneWidget);
    expect(filterField, findsOneWidget);
    expect(shelfTitle('书一'), findsNothing);

    // 点清除（有关键词）→ 恢复全部，过滤条仍在
    await tester.tap(filterClear);
    await tester.pumpAndSettle();
    expect(shelfTitle('书一'), findsOneWidget);
    expect(shelfTitle('书二'), findsOneWidget);
    expect(filterField, findsOneWidget);

    // 再点清除（无关键词）→ 退出过滤
    await tester.tap(filterClear);
    await tester.pumpAndSettle();
    expect(filterField, findsNothing);
    expect(find.byTooltip('搜索'), findsOneWidget);
  });
}
