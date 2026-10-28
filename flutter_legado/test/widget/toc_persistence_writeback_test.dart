// [批31b P1-1 / 批32] 目录页配置持久化回写回归（先红后绿）
//
// 批32 变更：倒序目录/目录显示反转改用单键写 `updateReadConfigField`
// （整书 updateBook 会清空 Dart 未建模的 readConfig 键）；本用例的
// mock 按 Rust 单键合并语义更新「DB」中的 readConfig。
//
// 缺陷路径（真机可复现）：
// 1. 阅读器/详情页打开目录时传入的是调用方持有的 Book 旧快照；
// 2. 目录页勾选「目录显示反转/倒序目录」→ `updateBook` 已落库，
//    但 `_book` 只在目录页内部更新，阅读器 `currentBook` 与详情页
//    `_loadedBook` 仍是旧快照；
// 3. pop 返回后同一 Book 对象重开目录：`_initBookshelfState` 只读
//    `_inBookshelf`，`_book` 仍是旧快照 → 勾选状态丢失；
// 4. 阅读器后续任意整书 `updateBook`（设置保存/进度回写）用旧快照
//    把 DB 已落库的配置还原。
//
// 修复：
// - 目录页 init 以 DB 记录刷新 `_book`（DB 为准）；
// - 目录页 `_updateBook` 落库后同步 ReaderNotifier.currentBook（同书）；
// - 阅读器 `RouteAware.didPopNext` 重读 DB（见 reader_screen.dart）；
// - 详情页目录返回重读 `_loadedBook`（见 book_info_screen_builders）。
//
// 编写：全栈工程师（批31b） ｜ 2026-10-28
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
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
  late Book dbBook;

  setUpAll(registerFallbacks);

  const String bookUrl = 'https://src.com/book/persist';

  Book makeBook({bool reverseToc = false, bool reverseTocDisplay = false}) =>
      Book(
        bookUrl: bookUrl,
        name: '持久化测试书',
        author: '作者P',
        origin: 'https://src.com',
        totalChapterNum: 3,
        durChapterIndex: 1,
        durChapterTitle: '第二章',
        readConfig: ReadConfig(
          reverseToc: reverseToc,
          reverseTocDisplay: reverseTocDisplay,
        ),
      );

  List<BookChapter> chapters() => const [
    BookChapter(url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
    BookChapter(url: 'u1', title: '第二章', index: 1, bookUrl: bookUrl),
    BookChapter(url: 'u2', title: '第三章', index: 2, bookUrl: bookUrl),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    dbBook = makeBook();
    when(() => mockApi.getBook(any())).thenAnswer((_) async => dbBook);
    when(() => mockApi.updateBook(any())).thenAnswer((invocation) async {
      dbBook = invocation.positionalArguments.first as Book;
    });
    // [批32] 单键写：模拟 Rust 在 DB 侧只合并目标键（其余键保留）
    when(
      () => mockApi.updateReadConfigField(any(), any(), any()),
    ).thenAnswer((invocation) async {
      final url = invocation.positionalArguments[0] as String;
      final key = invocation.positionalArguments[1] as String;
      final value = jsonDecode(invocation.positionalArguments[2] as String);
      if (url != dbBook.bookUrl || value is! bool) return;
      final cfg = dbBook.readConfig ?? const ReadConfig();
      dbBook = dbBook.copyWith(
        readConfig: switch (key) {
          'reverseToc' => cfg.copyWith(reverseToc: value),
          'reverseTocDisplay' => cfg.copyWith(reverseTocDisplay: value),
          _ => cfg,
        },
      );
    });
    when(
      () => mockApi.getChapters(bookUrl),
    ).thenAnswer((_) async => chapters());
    when(
      () => mockApi.listCachedChapterUrls(bookUrl),
    ).thenAnswer((_) async => const <String>[]);
    when(
      () => mockApi.listDownloadingChapters(bookUrl),
    ).thenAnswer((_) async => const <int>[]);
    when(
      () => mockApi.listFailedChapters(bookUrl),
    ).thenAnswer((_) async => const <int>[]);
    when(
      () => mockApi.highlightListByBook(bookUrl: bookUrl),
    ).thenAnswer((_) async => '[]');
    when(
      () => mockApi.getBookmarksByBook('持久化测试书', '作者P'),
    ).thenAnswer((_) async => const <Bookmark>[]);
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: child),
  );

  /// 宿主页：按钮 push 目录页（模拟阅读器/详情页传旧快照）
  Widget host(Book book) => wrap(
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push<int>(
              MaterialPageRoute(builder: (_) => TocScreen(book: book)),
            ),
            child: const Text('打开目录'),
          ),
        ),
      ),
    ),
  );

  /// 推进目录页初始异步链（getBook → getChapters → 各状态查询）。
  /// 在线书有 1s 轮询定时器，不用 pumpAndSettle。
  Future<void> settleInitial(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> openToc(WidgetTester tester) async {
    await tester.tap(find.text('打开目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settleInitial(tester);
  }

  Future<void> popRoute(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> toggleMenuItem(WidgetTester tester, String label) async {
    await openMenu(tester);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, label));
    await tester.pump();
    await settleInitial(tester);
    await tester.pump(const Duration(milliseconds: 300));
  }

  bool checkedOf(WidgetTester tester, String label) => tester
      .widget<CheckedPopupMenuItem<String>>(
        find.widgetWithText(CheckedPopupMenuItem<String>, label),
      )
      .checked;

  testWidgets('旧快照打开目录：两个勾选项落库后，同一对象重开仍为勾选', (tester) async {
    // 调用方持有的旧快照（与 DB 初始一致）
    final stale = makeBook();
    await tester.pumpWidget(host(stale));
    await openToc(tester);

    // 勾选「倒序目录」（数据反转）与「目录显示反转」（展示反转）
    await toggleMenuItem(tester, '倒序目录');
    await toggleMenuItem(tester, '目录显示反转');

    expect(dbBook.readConfig?.reverseToc, isTrue, reason: '倒序目录应已落库');
    expect(dbBook.readConfig?.reverseTocDisplay, isTrue, reason: '目录显示反转应已落库');

    // 返回后以同一旧快照对象重开目录
    await popRoute(tester);
    await openToc(tester);
    await openMenu(tester);

    expect(
      checkedOf(tester, '倒序目录'),
      isTrue,
      reason: '重开目录应读到已落库的数据反转（旧快照不得覆盖 DB）',
    );
    expect(checkedOf(tester, '目录显示反转'), isTrue, reason: '重开目录应读到已落库的显示反转');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('目录页改配置同步阅读器 currentBook：阅读器整书保存不还原 DB', (tester) async {
    final stale = makeBook();
    // 模拟阅读器已打开本书：currentBook 为打开时的旧快照
    container.read(readerNotifierProvider.notifier).updateCurrentBook(stale);

    await tester.pumpWidget(wrap(TocScreen(book: stale)));
    await settleInitial(tester);

    await toggleMenuItem(tester, '目录显示反转');

    expect(dbBook.readConfig?.reverseTocDisplay, isTrue, reason: '目录页应落库');
    expect(
      container
          .read(readerNotifierProvider)
          .currentBook
          ?.readConfig
          ?.reverseTocDisplay,
      isTrue,
      reason: '目录页落库后必须同步 ReaderNotifier.currentBook（旧快照回写防护）',
    );

    // 模拟阅读器后续整书保存：用 currentBook 调 updateBook
    final readerBook = container.read(readerNotifierProvider).currentBook!;
    await mockApi.updateBook(readerBook);
    expect(
      dbBook.readConfig?.reverseTocDisplay,
      isTrue,
      reason: '阅读器整书回写不得把目录页已落库的配置还原',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
