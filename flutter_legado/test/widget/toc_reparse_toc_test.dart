// [批1b-3 复验 P2-5/P3-4] 目录页「重新解析目录」行为测试 — 全栈工程师
//
// 覆盖：
// 1. 本地 TXT 目录 Tab 溢出菜单含「重新解析目录」项（非本地 TXT 不显示）；
// 2. 点击后调用 setBookTocRule（拆回当前 tocUrl 的规则 JSON，失效通道）；
// 3. setBookTocRule 抛错 → SnackBar 明示「重新解析目录失败」（fail-closed
//    不误报成功，口径对齐 reader_toc_rule_dialog）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/toc_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  const bookUrl = 'books/reparse.txt';

  Book makeBook({String tocUrl = ''}) => const Book(
        bookUrl: bookUrl,
        name: '重解析测试书',
        author: '作者R',
        origin: BookType.localTag,
        originName: 'reparse.txt',
        totalChapterNum: 2,
      ).copyWith(tocUrl: tocUrl);

  List<BookChapter> chapters() => const [
        BookChapter(url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
        BookChapter(url: 'u1', title: '第二章', index: 1, bookUrl: bookUrl),
      ];

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    when(() => mockApi.getBook(any())).thenAnswer((_) async => makeBook());
    when(() => mockApi.getChapters(bookUrl))
        .thenAnswer((_) async => chapters());
    when(() => mockApi.listCachedChapterUrls(bookUrl))
        .thenAnswer((_) async => const <String>[]);
    when(() => mockApi.listDownloadingChapters(bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.listFailedChapters(bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('重解析测试书', '作者R'))
        .thenAnswer((_) async => const <Bookmark>[]);
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: child),
      );

  Future<void> openToc(WidgetTester tester, Book book) async {
    await tester.pumpWidget(wrap(TocScreen(book: book)));
    // 推进初始异步链（getBook → getChaptersWithMeta → 状态查询）；在线书
    // 有 1s 轮询定时器，不用 pumpAndSettle
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  testWidgets('本地 TXT 目录 Tab 溢出菜单含「重新解析目录」（对齐参考版 update_toc）',
      (tester) async {
    await openToc(tester, makeBook());
    await openMenu(tester);

    expect(find.text('重新解析目录'), findsOneWidget);
    expect(find.text('TXT 目录规则'), findsOneWidget);
  });

  testWidgets('点击「重新解析目录」→ 调 setBookTocRule（默认书传 null）并提示成功',
      (tester) async {
    final book = makeBook();
    when(() => mockApi.setBookTocRule(bookUrl, null))
        .thenAnswer((_) async => book);
    await openToc(tester, book);
    await openMenu(tester);

    await tester.tap(find.text('重新解析目录'));
    await tester.pumpAndSettle();

    verify(() => mockApi.setBookTocRule(bookUrl, null)).called(1);
    expect(find.text('已重新解析目录（共 2 章）'), findsOneWidget);
  });

    testWidgets('带规则的书：拆回 {rule, replacement} JSON 写回（不走 null）',
        (tester) async {
      const tocUrl = r'^【第.+篇】.*$🫅🈳🏻result.replace("【","")';
      final book = makeBook(tocUrl: tocUrl);
      final ruleArgs = <String?>[];
      when(() => mockApi.setBookTocRule(bookUrl, any()))
          .thenAnswer((invocation) async {
        ruleArgs.add(invocation.positionalArguments[1] as String?);
        return book;
      });
      await openToc(tester, book);
      await openMenu(tester);

      await tester.tap(find.text('重新解析目录'));
      await tester.pumpAndSettle();

      // 拆回 JSON：rule/replacement 与原 tocUrl 逐字对应
      expect(ruleArgs, hasLength(1));
      final decoded =
          jsonDecode(ruleArgs.single!) as Map<String, dynamic>;
      expect(decoded['rule'], r'^【第.+篇】.*$');
      expect(decoded['replacement'], 'result.replace("【","")');
      verifyNever(() => mockApi.setBookTocRule(bookUrl, null));
    });

  testWidgets('setBookTocRule 抛错 → SnackBar「重新解析目录失败」（不误报成功）',
      (tester) async {
    final book = makeBook();
    when(() => mockApi.setBookTocRule(bookUrl, any()))
        .thenThrow(Exception('目录规则正则无效'));
    await openToc(tester, book);
    await openMenu(tester);

    await tester.tap(find.text('重新解析目录'));
    await tester.pumpAndSettle();

    expect(find.textContaining('重新解析目录失败'), findsOneWidget);
    expect(find.textContaining('已重新解析目录'), findsNothing,
        reason: 'fail-closed：清表失败不得提示成功');
  });

  testWidgets('非本地 TXT 不显示该菜单项（入口与 Rust 准入同构）', (tester) async {
    const epubBook = Book(
      bookUrl: 'books/a.epub',
      name: 'EPUB 书',
      origin: BookType.localTag,
      originName: 'a.epub',
      totalChapterNum: 1,
    );
    when(() => mockApi.getBook(epubBook.bookUrl))
        .thenAnswer((_) async => epubBook);
    when(() => mockApi.getChapters(epubBook.bookUrl))
        .thenAnswer((_) async => const [
              BookChapter(url: 'e0', title: '一章', index: 0, bookUrl: 'books/a.epub'),
            ]);
    when(() => mockApi.listCachedChapterUrls(epubBook.bookUrl))
        .thenAnswer((_) async => const <String>[]);
    when(() => mockApi.listDownloadingChapters(epubBook.bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.listFailedChapters(epubBook.bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.highlightListByBook(bookUrl: epubBook.bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('EPUB 书', '作者R'))
        .thenAnswer((_) async => const <Bookmark>[]);

    await openToc(tester, epubBook);
    await openMenu(tester);

    expect(find.text('重新解析目录'), findsNothing);
    expect(find.text('TXT 目录规则'), findsNothing);
  });
}
