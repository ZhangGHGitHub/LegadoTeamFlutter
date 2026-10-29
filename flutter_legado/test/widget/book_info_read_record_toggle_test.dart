// [批35] 书籍详情页「独立关闭阅读记录」菜单项：
// - 仅在架书籍显示（对齐参考版 BookInfoMenuAction.ToggleReadRecordDisabled
//   的 `inBookshelf && book != null` 条件）；
// - 点击调用 setReadRecordDisabled 单列写并给出结果提示。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';

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

  Future<void> loadGroups() async {
    when(() => mockApi.getBooks()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
    await container.read(bookshelfNotifierProvider.notifier).refresh();
  }

  void stubBook(Book? dbBook, Book routeBook) {
    when(() => mockApi.getBook(any())).thenAnswer((_) async => dbBook);
    when(() => mockApi.getChapters(any())).thenAnswer((_) async => const []);
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

  testWidgets('在架书籍：菜单点击后单列写开关并提示已关闭', (tester) async {
    final book = Book(
      bookUrl: 'https://src.com/book/rr',
      name: '阅读记录书',
      author: '作者',
      origin: 'https://src.com',
      bookType: BookType.text,
    );
    stubBook(book, book);
    when(() => mockApi.setReadRecordDisabled(book.bookUrl, true))
        .thenAnswer((_) async => book.copyWith(disableReadRecord: true));
    await loadGroups();

    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('独立关闭阅读记录'), findsOneWidget,
        reason: '在架书籍菜单应显示书籍级阅读记录开关');

    await tester.tap(find.text('独立关闭阅读记录'));
    await tester.pumpAndSettle();

    verify(() => mockApi.setReadRecordDisabled(book.bookUrl, true)).called(1);
    expect(find.text('已关闭本书阅读记录'), findsOneWidget);
  });

  testWidgets('未入库临时书：菜单不显示书籍级阅读记录开关', (tester) async {
    final book = Book(
      bookUrl: 'https://src.com/book/not-shelf',
      name: '临时书',
      author: '作者',
      origin: 'https://src.com',
      // notShelf 位：搜索/发现打开，不算在书架内
      bookType: BookType.text | BookType.notShelf,
    );
    stubBook(null, book);
    await loadGroups();

    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('独立关闭阅读记录'), findsNothing,
        reason: '未在架书籍不提供书籍级阅读记录开关');
  });
}
