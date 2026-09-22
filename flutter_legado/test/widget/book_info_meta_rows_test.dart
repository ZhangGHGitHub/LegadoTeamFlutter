// [08 元信息区对齐 | 台账 0922 修订] 书籍详情页元信息区元素集回归守卫：
// 对标参考 io.legato.kazusa 08 屏（docs/parity_shots/ref_20260914/08_book_info.png
// + ref_dark_20260920/08_book_info.xml + 参考源 BookInfoScreen.kt/HighlightTagRow.kt）：
// - 无独立「目录：」行（目录入口仅保留四按钮「查看目录」卡）
// - 无独立「分组：」行（分组信息收编入 chips 行条件 chip；无分组不显「未分组」）
// - 无「🏷️ 标签行」（参考 08 无此行；kind 信息即 chips 行逐项，
//   原标签行的点击搜索/长按 JS 回调手势迁至 kind chip，功能不丢）
// - chips 行无章数 chip（章数由「共 N 章」行承载）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';

import '../mocks/mocks.dart';

/// 记录 push 的路由名（kind chip 点击 → 搜索页断言用）
class _PushedRouteObserver extends NavigatorObserver {
  final List<String> pushed;
  _PushedRouteObserver(this.pushed);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name ?? '');
  }
}

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
      ],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  /// 预载书架分组（分组 chip 读取 bookshelfNotifierProvider.groups）
  Future<void> loadGroups(List<BookGroup> groups) async {
    when(() => mockApi.getBooks()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => groups);
    await container.read(bookshelfNotifierProvider.notifier).refresh();
  }

  void stubBook(Book book, [List<BookChapter> chapters = const []]) {
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(any()))
        .thenAnswer((_) async => chapters);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(() => mockApi.sourceCallBackBtn(
          event: any(named: 'event'),
          bookUrl: any(named: 'bookUrl'),
          result: any(named: 'result'),
          bookType: any(named: 'bookType'),
        )).thenAnswer((_) async => {
          'invoked': false,
          'jsTrue': false,
          'actions': <dynamic>[],
        });
  }

  group('book_info_meta_rows', () {
    testWidgets('无独立「目录：」/「分组：」行、无「🏷️ 标签行」，'
        'kind 信息以 chips 行呈现，章数由「共 N 章」行承载', (tester) async {
      final book = Book(
        bookUrl: 'https://src.com/book/meta',
        name: '元信息书',
        author: '作者',
        kind: '奇幻,武侠',
        wordCount: '142.20万字',
        totalChapterNum: 711,
      );
      stubBook(book, [
        BookChapter(
            bookUrl: book.bookUrl, index: 0, title: '引子 穿越的唐家三少'),
      ]);
      await loadGroups(const []);

      await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
      await tester.pumpAndSettle();

      // 去噪三行：独立目录行/分组行/🏷️ 标签行均不渲染
      expect(find.textContaining('目录：'), findsNothing);
      expect(find.textContaining('分组：'), findsNothing);
      expect(find.textContaining('🏷️'), findsNothing);
      // 目录入口保留于四按钮「查看目录」卡
      expect(find.text('查看目录'), findsOneWidget);
      // kind 信息仍在（chips 行逐项），字数 chip 同在
      expect(find.text('奇幻'), findsOneWidget);
      expect(find.text('武侠'), findsOneWidget);
      expect(find.text('142.20万字'), findsOneWidget);
      // 章数只出现在「共 N 章」行，chips 行无「711章」项
      expect(find.textContaining('共 711 章'), findsOneWidget);
      expect(find.text('711章'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // 注：BookInfoScreen 仅在 initState 加载（无 didUpdateWidget 重载），
    // 同树位 re-pump 会复用 State/_loadedBook，故有/无分组分两个独立
    // testWidgets（各起全新 State）
    testWidgets('分组 chip：有分组时显示裸分组名（无「分组：」前缀、'
        '无「未分组」兜底）', (tester) async {
      final groupedBook = Book(
        bookUrl: 'https://src.com/book/g1',
        name: '分组书',
        author: '作者',
        kind: '轻小说',
        group: 1, // 位掩码命中 groupId=1
      );
      stubBook(groupedBook, const []);
      await loadGroups(const [
        BookGroup(groupId: 1, groupName: '武侠', order: 0),
      ]);

      await tester.pumpWidget(wrap(BookInfoScreen(book: groupedBook)));
      await tester.pumpAndSettle();

      // 有分组：chips 行出现分组 chip（裸分组名，对齐参考 values-zh-rCN
      // group_s=%s——不带「分组：」前缀）
      expect(find.text('武侠'), findsOneWidget);
      expect(find.textContaining('分组：'), findsNothing);
      expect(find.textContaining('未分组'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('分组 chip：无分组时不显示（不显「未分组」，kind chip 不丢）',
        (tester) async {
      final ungroupedBook = Book(
        bookUrl: 'https://src.com/book/g2',
        name: '无分组书',
        author: '作者',
        kind: '轻小说',
        group: 0, // 位掩码 0 不命中任何分组
      );
      stubBook(ungroupedBook, const []);
      // 书架里确有分组（武侠），证明不显示是书籍无分组而非分组列表为空
      await loadGroups(const [
        BookGroup(groupId: 1, groupName: '武侠', order: 0),
      ]);

      await tester.pumpWidget(wrap(BookInfoScreen(book: ungroupedBook)));
      await tester.pumpAndSettle();

      expect(find.text('武侠'), findsNothing);
      expect(find.textContaining('未分组'), findsNothing);
      expect(find.textContaining('分组：'), findsNothing);
      // kind 信息不丢：chips 行仍有 kind chip
      expect(find.text('轻小说'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chips 行无章数 chip（kind/字数各一 chip）', (tester) async {
      final book = Book(
        bookUrl: 'https://src.com/book/chips',
        name: 'chips书',
        author: '作者',
        kind: '轻小说,已完结',
        wordCount: '120万字',
        totalChapterNum: 51,
      );
      stubBook(book, const []);
      await loadGroups(const []);

      await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
      await tester.pumpAndSettle();

      // kind 逐项成 chip（参考 kindLabels itemsIndexed 形态，
      // 「已完结」等状态词亦为普通 chip，无特殊解析）
      expect(find.text('轻小说'), findsOneWidget);
      expect(find.text('已完结'), findsOneWidget);
      expect(find.text('120万字'), findsOneWidget);
      // 章数项不在 chips 行（「51章」精确文本不出现；
      // 「共 51 章」为 ③ 三行块承载）
      expect(find.text('51章'), findsNothing);
      expect(find.textContaining('共 51 章'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('kind chip 点击进搜索页（原 🏷️ 行逐 tag 搜索入口迁移）',
        (tester) async {
      final pushed = <String>[];
      final observer = _PushedRouteObserver(pushed);
      final routes = Map<String, WidgetBuilder>.from(AppRoutes.routes)
        ..remove('/');
      routes[AppRoutes.search] = (_) => const Scaffold(
            key: Key('search-stub'),
            body: Text('搜索页'),
          );
      final book = Book(
        bookUrl: 'https://src.com/book/kindtap',
        name: '点tag书',
        author: '作者',
        kind: '奇幻,武侠',
      );
      stubBook(book, const []);
      await loadGroups(const []);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: BookInfoScreen(book: book),
          routes: routes,
          navigatorObservers: [observer],
        ),
      ));
      await tester.pumpAndSettle();

      // 点击 kind chip → push 搜索页（_openSearch：event=clickBookLabel）
      await tester.tap(find.text('奇幻'));
      await tester.pumpAndSettle();
      expect(pushed, contains(AppRoutes.search));
      expect(
        find.byKey(const Key('search-stub')),
        findsOneWidget,
      );

      // 返回详情页（同 Navigator pop；re-pump 会复用 NavigatorState，
      // 已 push 的搜索页仍在栈顶，故用 pop 恢复 chip 行可见）
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-stub')), findsNothing);

      // 长按 kind chip → JS 回调（event=longClickBookLabel，
      // 原 🏷️ 行长按入口迁移，功能不丢）
      await tester.longPress(find.text('武侠'));
      await tester.pumpAndSettle();
      verify(() => mockApi.sourceCallBackBtn(
            event: 'longClickBookLabel',
            bookUrl: book.bookUrl,
            result: '武侠',
            bookType: 0,
          )).called(1);
      expect(tester.takeException(), isNull);
    });
  });
}
