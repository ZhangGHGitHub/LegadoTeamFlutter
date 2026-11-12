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
        child: MaterialApp(home: const SettingsScreen(), routes: routes),
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
