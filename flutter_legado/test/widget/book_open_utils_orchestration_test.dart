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
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/utils/book_open_utils.dart';

import '../mocks/mocks.dart';

/// [P2-E | 2026-09-30] BookOpenUtils.openBook 统一开书编排测试
/// （4 屏收敛后的公共入口）：
/// - 未读（durChapterIndex<=0 && durChapterPos<=0）→ 书籍详情页；
/// - 在线书籍按 origin 匹配书源（尾斜杠归一）解析类型位 → 视频路由；
/// - 欢迎页口径：全局 navigatorKey 导航 + 跳过未读进详情分支；
/// - 文本阅读器：先经 ReaderNotifier.openBook 装载再导航（无 arguments）。
/// — 全栈工程师 + UI
void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 记录 push 的路由（名称 + 参数）
  final observer = _RouteLogObserver();

  tearDown(() {
    observer.routes.clear();
  });

  /// 测试宿主：按钮点击触发 BookOpenUtils.openBook；
  /// 任意命名路由统一渲染 stub 页（避免 MaterialApp 未注册路由报错）
  Widget harness({
    required Book book,
    required MockRustApi api,
    _RecordingReaderNotifier? readerNotifier,
    bool useGlobalNavigator = false,
    bool unreadOpensBookInfo = true,
  }) {
    return ProviderScope(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        if (readerNotifier != null)
          readerNotifierProvider.overrideWith(() => readerNotifier),
      ],
      child: MaterialApp(
        navigatorKey:
            useGlobalNavigator ? PlatformBridgeService.navigatorKey : null,
        navigatorObservers: [observer],
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('stub:${settings.name}')),
        ),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => BookOpenUtils.openBook(
                  context,
                  ref,
                  book,
                  useGlobalNavigator: useGlobalNavigator,
                  unreadOpensBookInfo: unreadOpensBookInfo,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('未读（durChapterIndex=0 且 durChapterPos=0）→ 书籍详情页',
      (tester) async {
    const book = Book(bookUrl: 'https://ex.com/unread', name: '未读书');
    final api = MockRustApi();

    await tester.pumpWidget(harness(book: book, api: api));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(observer.lastName, AppRoutes.bookInfo);
    expect(observer.lastArguments, book);
    expect(find.text('stub:${AppRoutes.bookInfo}'), findsOneWidget);
  });

  testWidgets('在线书源匹配（尾斜杠归一 type=4）→ 视频路由且带类型位更新',
      (tester) async {
    final api = MockRustApi();
    when(() => api.getBookSources()).thenAnswer(
      (_) async => const [
        BookSource(
          bookSourceUrl: 'https://video.example.com',
          bookSourceName: '影视源',
          bookSourceType: 4,
        ),
      ],
    );
    // origin 带尾斜杠、书源 URL 不带：归一后应匹配（旧 home_tab 精确比较会漏配）
    const book = Book(
      bookUrl: 'https://video.example.com/play/1',
      name: '视频书',
      origin: 'https://video.example.com/',
      originName: '影视源',
      durChapterIndex: 3,
      bookType: BookType.text,
    );

    await tester.pumpWidget(harness(book: book, api: api));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(observer.lastName, AppRoutes.video);
    final args = observer.lastArguments;
    expect(args, isA<Book>());
    final argBook = args! as Book;
    expect(argBook.bookUrl, book.bookUrl);
    expect(argBook.bookType & BookType.video, BookType.video);
    expect(argBook.bookType & BookType.text, 0);
    verify(() => api.getBookSources()).called(1);
  });

  testWidgets('欢迎页口径：全局 navigatorKey + 跳过未读进详情 → 文本阅读器',
      (tester) async {
    const book = Book(
      bookUrl: 'loc_book_1',
      name: '本地未读书',
      origin: BookType.localTag,
      durChapterIndex: 0,
      durChapterPos: 0,
      bookType: BookType.text,
    );
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();

    await tester.pumpWidget(harness(
      book: book,
      api: api,
      readerNotifier: reader,
      useGlobalNavigator: true,
      unreadOpensBookInfo: false,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // unreadOpensBookInfo=false：index/pos 均 0 也不进详情页
    expect(observer.lastName, AppRoutes.reader);
    expect(observer.lastArguments, isNull);
    expect(reader.openedBook?.bookUrl, book.bookUrl);
  });

  testWidgets('文本阅读器：先装载 ReaderNotifier 再推 /reader（无参数）',
      (tester) async {
    const book = Book(
      bookUrl: 'loc_book_2',
      name: '本地已读书',
      origin: BookType.localTag,
      durChapterIndex: 2,
      durChapterPos: 10,
      bookType: BookType.text,
    );
    final api = MockRustApi();
    final reader = _RecordingReaderNotifier();

    await tester.pumpWidget(harness(
      book: book,
      api: api,
      readerNotifier: reader,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(observer.lastName, AppRoutes.reader);
    expect(observer.lastArguments, isNull);
    expect(reader.openedBook, book);
  });
}

/// 路由日志观察者：断言最终 push 的路由名与参数
class _RouteLogObserver extends NavigatorObserver {
  final List<Route<dynamic>> routes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    super.didPush(route, previousRoute);
  }

  String? get lastName => routes.last.settings.name;

  Object? get lastArguments => routes.last.settings.arguments;
}

/// 记录 openBook 调用的 ReaderNotifier 假实现（隔离真实阅读器状态加载）
class _RecordingReaderNotifier extends ReaderNotifier {
  Book? openedBook;

  @override
  ReaderState build() => const ReaderState();

  @override
  Future<void> openBook(Book book) async {
    openedBook = book;
  }
}
