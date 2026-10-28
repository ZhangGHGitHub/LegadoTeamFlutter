// [批31] 目录「显示反转」组合语义与点击映射回归
//
// 取证（原版 gedoor/legado `531f9fbf07`）：
// - `Book.kt:502`：`ReadConfig.reverseTocDisplay`（默认 false）；
// - `TocListState.kt:56-60`：`reverseOrder`（数据反转）先行，随后
//   `reverseDisplay`（显示反转）再反一次——双开回到原始顺序；
// - `ChapterListFragment.kt:193-194`：`reverseOrder = getReverseToc()`、
//   `reverseDisplay = getReverseTocDisplay()`（仅展示层，index 身份不变）。
//
// 本测试锁定：
// 1. 仅显示反转：展示序反、当前章高亮仍按真实 index、点击回传真实 index；
// 2. 数据反转 + 显示反转：两次反转回到原始顺序；
// 3. 仅数据反转：展示序反、点击末行回传第 0 章；
// 4. 目录溢出菜单两个勾选项独立（倒序目录 / 目录显示反转）。
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/toc_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: child),
      );

  const String bookUrl = 'https://src.com/book/1';

  List<BookChapter> chapters() => const [
        BookChapter(url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
        BookChapter(url: 'u1', title: '第二章', index: 1, bookUrl: bookUrl),
        BookChapter(url: 'u2', title: '第三章', index: 2, bookUrl: bookUrl),
      ];

  Book makeBook({
    bool reverseToc = false,
    bool reverseTocDisplay = false,
  }) =>
      Book(
        bookUrl: bookUrl,
        name: '测试书',
        author: '作者A',
        origin: 'https://src.com',
        totalChapterNum: 3,
        durChapterIndex: 1,
        durChapterTitle: '第二章',
        readConfig: ReadConfig(
          reverseToc: reverseToc,
          reverseTocDisplay: reverseTocDisplay,
        ),
      );

  void stubCommon(Book book) {
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(bookUrl)).thenAnswer((_) async => chapters());
    when(() => mockApi.listCachedChapterUrls(bookUrl))
        .thenAnswer((_) async => const <String>[]);
    when(() => mockApi.listDownloadingChapters(bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.listFailedChapters(bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);
    when(() => mockApi.updateBook(any())).thenAnswer((_) async {});
  }

  /// 初始渲染：build 帧 + 冲刷三次异步加载（不推进 1s 轮询定时器）
  Future<void> settleInitial(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  double dy(WidgetTester tester, String title) => tester
      .getTopLeft(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text(title),
        ),
      )
      .dy;

  /// 章节行标题（排除 AppBar 的当前章标题同名 Text）
  Finder rowTitle(String title) => find.descendant(
        of: find.byType(ListTile),
        matching: find.text(title),
      );

  testWidgets('仅显示反转：展示序反、当前章高亮与点击回传真实 index 不变',
      (tester) async {
    final book = makeBook(reverseTocDisplay: true);
    stubCommon(book);
    await tester.pumpWidget(wrap(TocScreen(book: book)));
    await settleInitial(tester);

    // 展示序：第三章 → 第二章 → 第一章
    expect(dy(tester, '第三章'), lessThan(dy(tester, '第二章')));
    expect(dy(tester, '第二章'), lessThan(dy(tester, '第一章')));
    // 当前章高亮仍来自真实 durChapterIndex=1（第二章），不是展示位置
    final current = tester.widget<ListTile>(
      find.ancestor(of: rowTitle('第二章'), matching: find.byType(ListTile)),
    );
    expect(current.tileColor, isNotNull, reason: '第二章应为当前章高亮');
    final other = tester.widget<ListTile>(
      find.ancestor(of: rowTitle('第三章'), matching: find.byType(ListTile)),
    );
    expect(other.tileColor, isNull);
    // 进度仍按真实 index 显示 2 / 3
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('数据反转 + 显示反转：两次反转回到原始顺序', (tester) async {
    final book = makeBook(reverseToc: true, reverseTocDisplay: true);
    stubCommon(book);
    await tester.pumpWidget(wrap(TocScreen(book: book)));
    await settleInitial(tester);

    expect(dy(tester, '第一章'), lessThan(dy(tester, '第二章')));
    expect(dy(tester, '第二章'), lessThan(dy(tester, '第三章')));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('仅数据反转：展示序反，点击末行回传第 0 章', (tester) async {
    final book = makeBook(reverseToc: true);
    stubCommon(book);
    int? result;
    await tester.pumpWidget(wrap(Builder(builder: (context) {
      return ElevatedButton(
        onPressed: () async {
          result = await Navigator.of(context).push<int>(
            MaterialPageRoute(builder: (_) => TocScreen(book: book)),
          );
        },
        child: const Text('打开目录'),
      );
    })));
    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();

    expect(dy(tester, '第三章'), lessThan(dy(tester, '第一章')));
    await tester.tap(rowTitle('第一章'));
    await tester.pumpAndSettle();

    expect(result, 0, reason: '末行「第一章」的真实章节 index 为 0');
  });

  testWidgets('菜单两个勾选项独立显示（倒序目录 / 目录显示反转）',
      (tester) async {
    final book = makeBook(reverseToc: true);
    stubCommon(book);
    await tester.pumpWidget(wrap(TocScreen(book: book)));
    await settleInitial(tester);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    final reverseTocItem = tester.widget<CheckedPopupMenuItem<String>>(
      find.widgetWithText(CheckedPopupMenuItem<String>, '倒序目录'),
    );
    final displayItem = tester.widget<CheckedPopupMenuItem<String>>(
      find.widgetWithText(CheckedPopupMenuItem<String>, '目录显示反转'),
    );
    expect(reverseTocItem.checked, isTrue);
    expect(displayItem.checked, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  // [批31b P3-4] 搜索过滤与双反转的组合顺序：先按关键词过滤，再按
  // 「数据反转 → 显示反转」两次反转（双开回到过滤结果的原始相对顺序）。
  testWidgets('搜索过滤 × 双反转：过滤后仍按原始相对顺序展示', (tester) async {
    final book = makeBook(reverseToc: true, reverseTocDisplay: true);
    stubCommon(book);
    // 覆盖目录：番外夹在中间，用于验证过滤先于反转
    when(() => mockApi.getChapters(bookUrl)).thenAnswer((_) async => const [
          BookChapter(url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
          BookChapter(url: 'u1', title: '番外', index: 1, bookUrl: bookUrl),
          BookChapter(url: 'u2', title: '第二章', index: 2, bookUrl: bookUrl),
        ]);
    await tester.pumpWidget(wrap(TocScreen(book: book)));
    await settleInitial(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '第');
    // 300ms 搜索防抖
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.text('番外'), findsNothing, reason: '不匹配关键词的行应被过滤');
    expect(
      dy(tester, '第一章'),
      lessThan(dy(tester, '第二章')),
      reason: '过滤结果经两次反转回到原始相对顺序',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
