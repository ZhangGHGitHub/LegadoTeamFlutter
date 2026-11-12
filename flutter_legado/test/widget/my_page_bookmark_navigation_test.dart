// 我的页 → 书签 → 点击书签跳章回归
//
// 原缺陷：SettingsScreen._openMyEntry 用 pushNamed 不等待返回值，书签页
// pop 的 {bookName, author, chapterIndex, chapterPos} 被丢弃，点击书签只
// 退回我的页。本文件覆盖：
// 1. 书签页 pop 结果带作者（供无 bookUrl 的书签按名 + 作者反查）；
// 2. 命中书架书籍 → openBook 收到正确的章节/位置并进入阅读器；
// 3. 书已不在架 → 中文提示且不跳转；
// 4. 查询失败/跳转失败 → 中文提示，不崩。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/bookmark_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/services/auto_task_scheduler.dart';

import '../mocks/fake_web_service_address_resolver.dart';
import '../mocks/mocks.dart';

/// 记录 openBook 入参的 ReaderNotifier 假实现（隔离真实阅读器加载）
class _RecordingReaderNotifier extends ReaderNotifier {
  Book? openedBook;

  @override
  ReaderState build() => const ReaderState();

  @override
  Future<void> openBook(Book book) async {
    openedBook = book;
  }
}

/// 书签页替身：按钮触发 pop，模拟用户点击某条书签
class _BookmarkResultPage extends StatelessWidget {
  const _BookmarkResultPage(this.result);

  final Map<String, Object?> result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey('emit_bookmark_result'),
          onPressed: () => Navigator.of(context).pop(result),
          child: const Text('emit'),
        ),
      ),
    );
  }
}

/// 记录 push 的路由名（断言第 0 章书签未误进详情页）
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AutoTaskScheduler.instance.debugReset();
    addTearDown(AutoTaskScheduler.instance.debugReset);
  });

  /// 我的页宿主（高画布一次性构建「其他」组，免滚动）
  Future<void> pumpMyPage(
    WidgetTester tester, {
    required MockRustApi api,
    required Map<String, WidgetBuilder> routes,
    _RecordingReaderNotifier? reader,
    NavigatorObserver? observer,
  }) async {
    tester.view.physicalSize = const Size(800, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => api.getServerStatus()).thenAnswer((_) async => 'stopped');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          webServiceAddressResolverProvider.overrideWithValue(
            FakeWebServiceAddressResolver(),
          ),
          if (reader != null) readerNotifierProvider.overrideWith(() => reader),
        ],
        child: MaterialApp(
          home: const SettingsScreen(),
          routes: routes,
          navigatorObservers: observer == null ? const [] : [observer],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openBookmarksAndEmit(WidgetTester tester) async {
    await tester.tap(find.text('书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emit_bookmark_result')));
    await tester.pumpAndSettle();
  }

  testWidgets('书签缺 bookUrl：按书名+作者反查书架并跳到书签章节', (tester) async {
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();
    const book = Book(
      bookUrl: 'u1',
      name: '书一',
      author: '作者甲',
      bookType: BookType.text,
      durChapterIndex: 0,
      durChapterPos: 0,
    );
    when(() => api.getBooks()).thenAnswer((_) async => const [book]);

    await pumpMyPage(
      tester,
      api: api,
      reader: reader,
      routes: {
        AppRoutes.bookmarks: (_) => const _BookmarkResultPage({
          'bookName': '书一',
          'author': '作者甲',
          'chapterIndex': 5,
          'chapterPos': 120,
        }),
        AppRoutes.reader: (_) => const Scaffold(body: Text('reader-stub')),
      },
    );
    await openBookmarksAndEmit(tester);

    expect(reader.openedBook, isNotNull);
    expect(reader.openedBook!.bookUrl, 'u1');
    expect(reader.openedBook!.durChapterIndex, 5);
    expect(reader.openedBook!.durChapterPos, 120);
    expect(find.text('reader-stub'), findsOneWidget);
    // 无 bookUrl → 走书架列表按名 + 作者反查，而不是 getBook
    verify(() => api.getBooks()).called(1);
    verifyNever(() => api.getBook(any()));
  });

  testWidgets('书已不在架：提示「该书已不在书架」且不跳转', (tester) async {
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();
    // 同名不同作者：按书名 + 作者精确匹配应落空
    when(() => api.getBooks()).thenAnswer(
      (_) async => const [Book(bookUrl: 'u2', name: '书一', author: '作者乙')],
    );

    await pumpMyPage(
      tester,
      api: api,
      reader: reader,
      routes: {
        AppRoutes.bookmarks: (_) => const _BookmarkResultPage({
          'bookName': '书一',
          'author': '作者甲',
          'chapterIndex': 1,
          'chapterPos': 0,
        }),
        AppRoutes.reader: (_) => const Scaffold(body: Text('reader-stub')),
      },
    );
    await openBookmarksAndEmit(tester);

    expect(find.text('该书已不在书架'), findsOneWidget);
    expect(reader.openedBook, isNull);
    expect(find.text('reader-stub'), findsNothing);
  });

  testWidgets('跳转失败：中文提示且不崩', (tester) async {
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();
    when(() => api.getBooks()).thenAnswer(
      (_) async => const [Book(bookUrl: 'u1', name: '书一', author: '作者甲')],
    );

    await pumpMyPage(
      tester,
      api: api,
      reader: reader,
      routes: {
        // 故意不注册 /reader：pushNamed 抛错，走失败提示分支
        AppRoutes.bookmarks: (_) => const _BookmarkResultPage({
          'bookName': '书一',
          'author': '作者甲',
          'chapterIndex': 2,
          'chapterPos': 0,
        }),
      },
    );
    await openBookmarksAndEmit(tester);

    expect(find.textContaining('打开书籍失败'), findsOneWidget);
  });

  testWidgets('第 0 章 0 位置书签：直达阅读器而非书籍详情', (tester) async {
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();
    final recorder = _RouteRecorder();
    const book = Book(
      bookUrl: 'u1',
      name: '书一',
      author: '作者甲',
      bookType: BookType.text,
      durChapterIndex: 0,
      durChapterPos: 0,
    );
    when(() => api.getBooks()).thenAnswer((_) async => const [book]);

    await pumpMyPage(
      tester,
      api: api,
      reader: reader,
      observer: recorder,
      routes: {
        AppRoutes.bookmarks: (_) => const _BookmarkResultPage({
          'bookName': '书一',
          'author': '作者甲',
          'chapterIndex': 0,
          'chapterPos': 0,
        }),
        AppRoutes.bookInfo: (_) => const Scaffold(body: Text('book-info-stub')),
        AppRoutes.reader: (_) => const Scaffold(body: Text('reader-stub')),
      },
    );
    await openBookmarksAndEmit(tester);

    // 若漏传 unreadOpensBookInfo:false，未读分支会先推 bookInfo
    expect(recorder.pushed, isNot(contains(AppRoutes.bookInfo)));
    expect(recorder.pushed, contains(AppRoutes.reader));
    expect(reader.openedBook, isNotNull);
    expect(reader.openedBook!.durChapterIndex, 0);
    expect(reader.openedBook!.durChapterPos, 0);
    expect(find.text('reader-stub'), findsOneWidget);
    expect(find.text('book-info-stub'), findsNothing);
  });

  testWidgets('书签结果携带 bookUrl：按 URL 查库并跳章', (tester) async {
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();
    const book = Book(
      bookUrl: 'u1',
      name: '书一',
      author: '作者甲',
      bookType: BookType.text,
      durChapterIndex: 0,
    );
    when(() => api.getBook('u1')).thenAnswer((_) async => book);

    await pumpMyPage(
      tester,
      api: api,
      reader: reader,
      routes: {
        AppRoutes.bookmarks: (_) => const _BookmarkResultPage({
          'bookUrl': 'u1',
          'bookName': '书一',
          'author': '作者甲',
          'chapterIndex': 4,
          'chapterPos': 9,
        }),
        AppRoutes.reader: (_) => const Scaffold(body: Text('reader-stub')),
      },
    );
    await openBookmarksAndEmit(tester);

    verify(() => api.getBook('u1')).called(1);
    verifyNever(() => api.getBooks());
    expect(reader.openedBook?.bookUrl, 'u1');
    expect(reader.openedBook?.durChapterIndex, 4);
    expect(reader.openedBook?.durChapterPos, 9);
  });

  testWidgets('书源失效（getBookSources 抛错）：中文兜底后仍按原类型开书', (tester) async {
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();
    const book = Book(
      bookUrl: 'https://src.example.com/book/1',
      name: '在线书',
      author: '作者甲',
      origin: 'https://src.example.com',
      originName: '失效源',
      bookType: BookType.text,
      durChapterIndex: 3,
    );
    when(() => api.getBooks()).thenAnswer((_) async => const [book]);
    when(() => api.getBookSources()).thenThrow(StateError('源已失效'));

    await pumpMyPage(
      tester,
      api: api,
      reader: reader,
      routes: {
        AppRoutes.bookmarks: (_) => const _BookmarkResultPage({
          'bookName': '在线书',
          'author': '作者甲',
          'chapterIndex': 7,
          'chapterPos': 0,
        }),
        AppRoutes.reader: (_) => const Scaffold(body: Text('reader-stub')),
      },
    );
    await openBookmarksAndEmit(tester);

    expect(find.textContaining('打开书籍失败'), findsNothing);
    expect(reader.openedBook?.bookUrl, book.bookUrl);
    expect(reader.openedBook?.durChapterIndex, 7);
    expect(find.text('reader-stub'), findsOneWidget);
  });

  testWidgets('同名书多本命中：先让用户选择，不默认取第一条', (tester) async {
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();
    when(() => api.getBooks()).thenAnswer(
      (_) async => const [
        Book(bookUrl: 'u1', name: '书一', author: '作者甲', originName: '源甲'),
        Book(bookUrl: 'u2', name: '书一', author: '作者甲', originName: '源乙'),
      ],
    );

    await pumpMyPage(
      tester,
      api: api,
      reader: reader,
      routes: {
        AppRoutes.bookmarks: (_) => const _BookmarkResultPage({
          'bookName': '书一',
          'author': '作者甲',
          'chapterIndex': 2,
          'chapterPos': 0,
        }),
        AppRoutes.reader: (_) => const Scaffold(body: Text('reader-stub')),
      },
    );
    await openBookmarksAndEmit(tester);

    expect(find.text('选择书籍'), findsOneWidget);
    expect(reader.openedBook, isNull, reason: '选择前不得默认打开第一条');

    await tester.tap(find.byKey(const ValueKey('bookmarkBookChoice_u2')));
    await tester.pumpAndSettle();
    expect(reader.openedBook?.bookUrl, 'u2');
    expect(reader.openedBook?.durChapterIndex, 2);
  });

  testWidgets('书签页 pop 结果携带作者/章节/位置', (tester) async {
    final api = MockRustApi();
    when(() => api.getAllBookmarks()).thenAnswer(
      (_) async => const [
        Bookmark(
          bookName: '书一',
          bookAuthor: '作者甲',
          chapterName: '第三章',
          chapterIndex: 3,
          chapterPos: 7,
        ),
      ],
    );
    Map<String, Object?>? popped;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = await Navigator.push<Map<String, Object?>>(
                      context,
                      MaterialPageRoute(builder: (_) => const BookmarkScreen()),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书一'));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!['bookName'], '书一');
    expect(popped!['author'], '作者甲');
    expect(popped!['chapterIndex'], 3);
    expect(popped!['chapterPos'], 7);
  });
}
