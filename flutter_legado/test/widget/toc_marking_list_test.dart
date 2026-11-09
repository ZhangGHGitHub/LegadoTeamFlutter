/// 目录「标注」页笔记区测试（契约 §2.52，批7b-2a）
///
/// 覆盖：笔记列表加载（章节/效果/文本/备注/时间）、启停、编辑 Sheet 删除、
/// 长按跳转章节、空态不显示笔记区块。
library;

import 'package:flutter/material.dart';
import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
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

  const bookUrl = 'https://src.com/book/1';
  const bookName = '测试书';
  const bookAuthor = '作者A';

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

  Book makeBook() => const Book(
    bookUrl: bookUrl,
    name: bookName,
    author: bookAuthor,
    origin: 'https://src.com',
    totalChapterNum: 2,
    durChapterIndex: 0,
  );

  List<BookChapter> chapters() => const [
    BookChapter(url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
    BookChapter(url: 'u1', title: '第二章', index: 1, bookUrl: bookUrl),
  ];

  BookMarking makeMarking({
    required String id,
    required int chapterIndex,
    required String selectedText,
    required String note,
    required MarkingEffect effect,
    bool enabled = true,
    int updatedAt = 2000,
  }) {
    return BookMarking(
      id: id,
      bookUrl: bookUrl,
      bookName: bookName,
      bookAuthor: bookAuthor,
      chapterIndex: chapterIndex,
      anchorJson: buildBookMarkingAnchor(
        chapterIndex: chapterIndex,
        chapterPosition: 10 + chapterIndex,
        selectedText: selectedText,
      ).encode(),
      styleJson: effect.toStyle(0xFF22C55E).encode(),
      note: note,
      chapterName: '第${chapterIndex + 1}章',
      enabled: enabled,
      createdAt: 1000,
      updatedAt: updatedAt,
    );
  }

  void stubCommon({List<BookMarking> markings = const []}) {
    when(() => mockApi.getBook(any())).thenAnswer((_) async => makeBook());
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
      () => mockApi.getBookmarksByBook(bookName, bookAuthor),
    ).thenAnswer((_) async => const <Bookmark>[]);
    when(
      () => mockApi.getBookMarkingsByBook(bookName, bookAuthor),
    ).thenAnswer((_) async => markings);
    when(
      () => mockApi.setBookMarkingEnabled(any(), any()),
    ).thenAnswer((_) async {});
    when(() => mockApi.deleteBookMarking(any())).thenAnswer((_) async {});
    when(() => mockApi.updateBook(any())).thenAnswer((_) async {});
  }

  Future<void> settleInitial(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> openAnnotationsTab(WidgetTester tester) async {
    await tester.tap(find.text('标注'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('笔记区：按章列出效果/文本/备注/章节名，位于高亮列表上方', (tester) async {
    stubCommon(
      markings: [
        makeMarking(
          id: 'm1',
          chapterIndex: 0,
          selectedText: '第一段笔记',
          note: '重要备注',
          effect: MarkingEffect.wave,
        ),
        makeMarking(
          id: 'm2',
          chapterIndex: 1,
          selectedText: '第二段笔记',
          note: '',
          effect: MarkingEffect.strike,
        ),
      ],
    );
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);
    await openAnnotationsTab(tester);

    expect(find.byKey(const ValueKey('toc-section-笔记')), findsOneWidget);
    expect(find.text('第一段笔记'), findsOneWidget);
    expect(find.text('第二段笔记'), findsOneWidget);
    expect(find.text('备注: 重要备注'), findsOneWidget);
    expect(find.text('波浪线'), findsOneWidget);
    expect(find.text('删除线'), findsOneWidget);
    expect(find.byKey(const ValueKey('toc-marking-tile-m1')), findsOneWidget);
    expect(find.byKey(const ValueKey('toc-marking-tile-m2')), findsOneWidget);

    // 笔记区在所有高亮行之上（本用例无高亮行，仅验证区块存在）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('启停开关调用 setBookMarkingEnabled 并更新行状态', (tester) async {
    stubCommon(
      markings: [
        makeMarking(
          id: 'm1',
          chapterIndex: 0,
          selectedText: '第一段笔记',
          note: '备注',
          effect: MarkingEffect.solid,
        ),
      ],
    );
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);
    await openAnnotationsTab(tester);

    final switchFinder = find.byKey(const ValueKey('toc-marking-switch-m1'));
    expect(tester.widget<Switch>(switchFinder).value, isTrue);
    await tester.tap(switchFinder);
    await tester.pump();
    await tester.pump();
    verify(() => mockApi.setBookMarkingEnabled('m1', false)).called(1);
    expect(tester.widget<Switch>(switchFinder).value, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点笔记行打开编辑 Sheet；删除后列表移除', (tester) async {
    stubCommon(
      markings: [
        makeMarking(
          id: 'm1',
          chapterIndex: 0,
          selectedText: '第一段笔记',
          note: '备注',
          effect: MarkingEffect.solid,
        ),
      ],
    );
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);
    await openAnnotationsTab(tester);

    await tester.tap(find.byKey(const ValueKey('toc-marking-tile-m1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('编辑笔记'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('marking-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('marking-delete-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    verify(() => mockApi.deleteBookMarking('m1')).called(1);
    expect(find.byKey(const ValueKey('toc-marking-tile-m1')), findsNothing);
    expect(find.text('第一段笔记'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('空态：无笔记与高亮时不显示笔记区块，显示暂无标注', (tester) async {
    stubCommon(markings: const []);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);
    await openAnnotationsTab(tester);

    expect(find.byKey(const ValueKey('toc-section-笔记')), findsNothing);
    expect(find.text('暂无标注'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P2-3 笔记加载失败：显示错误页而非「暂无标注」', (tester) async {
    stubCommon(markings: const []);
    when(
      () => mockApi.getBookMarkingsByBook(bookName, bookAuthor),
    ).thenAnswer((_) async => throw const BridgeError(message: '笔记加载失败'));
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);
    await openAnnotationsTab(tester);

    expect(find.text('笔记加载失败'), findsOneWidget);
    expect(find.text('暂无标注'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P2-3 高亮非空时笔记失败仍显示错误行与重试', (tester) async {
    stubCommon(markings: const []);
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl)).thenAnswer(
      (_) async =>
          '[{"time":1,"bookUrl":"$bookUrl","chapterIndex":0,'
          '"chapterName":"第一章","bookText":"高亮文本","note":""}]',
    );
    when(
      () => mockApi.getBookMarkingsByBook(bookName, bookAuthor),
    ).thenAnswer((_) async => throw const BridgeError(message: '笔记加载失败'));
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);
    await openAnnotationsTab(tester);

    expect(find.byKey(const ValueKey('toc-marking-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('toc-marking-retry')), findsOneWidget);
    expect(find.textContaining('笔记加载失败'), findsOneWidget);
    expect(find.text('高亮文本'), findsOneWidget, reason: '高亮列表不受影响');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('长按笔记行返回对应章节索引', (tester) async {
    stubCommon(
      markings: [
        makeMarking(
          id: 'm2',
          chapterIndex: 1,
          selectedText: '第二章笔记',
          note: '',
          effect: MarkingEffect.text,
        ),
      ],
    );
    int? popped;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-toc'),
                onPressed: () async {
                  popped = await Navigator.of(context).push<int>(
                    MaterialPageRoute(
                      builder: (_) => TocScreen(book: makeBook()),
                    ),
                  );
                },
                child: const Text('打开目录'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-toc')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();
    await openAnnotationsTab(tester);

    await tester.longPress(find.byKey(const ValueKey('toc-marking-tile-m2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(popped, 1);
  });
}
