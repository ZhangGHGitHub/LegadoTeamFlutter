// 批9a 项4：漫画浏览开关（showMangaUi）开书分流编排测试
//
// 对齐参考版 BookInfoRouteScreen.kt:147 / ContextExtensions.kt:78 语义：
// - showMangaUi=false 时**在线**图片书回落文本阅读器 /reader（经
//   ReaderNotifier.openBook 装载，正文为 <img> 时由文本阅读器
//   isImageDominantContent 分支兜底出图）；
// - 本地图片书（cbz，LOCAL|image=0x1040）恒走 /reader-comic；
// - 开关默认 true，既有行为不变。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/utils/book_open_utils.dart';

import '../mocks/mocks.dart';

/// 捕获 openBook 的 ReaderNotifier（复用编排测试同型 stub）
class _RecordingReaderNotifier extends ReaderNotifier {
  Book? openedBook;

  @override
  ReaderState build() => const ReaderState();

  @override
  Future<void> openBook(Book book) async {
    openedBook = book;
  }
}

class _RouteLogObserver extends NavigatorObserver {
  final List<String> routes = [];
  String? get lastName => routes.isEmpty ? null : routes.last;
  Object? lastArguments;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route.settings.name ?? '');
    lastArguments = route.settings.arguments;
  }
}

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookOpenUtils.showMangaUi = true; // 重置镜像
  });

  final observer = _RouteLogObserver();

  tearDown(() {
    observer.routes.clear();
  });

  Widget harness({
    required Book book,
    required MockRustApi api,
    _RecordingReaderNotifier? readerNotifier,
  }) {
    return ProviderScope(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        if (readerNotifier != null)
          readerNotifierProvider.overrideWith(() => readerNotifier),
      ],
      child: MaterialApp(
        navigatorKey: PlatformBridgeService.navigatorKey,
        navigatorObservers: [observer],
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('stub:${settings.name}')),
        ),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => BookOpenUtils.openBook(context, ref, book),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('开关默认 true：在线图片书 → /reader-comic（默认行为不变）',
      (tester) async {
    final api = MockRustApi();
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    const book = Book(
      bookUrl: 'https://comic.example.com/1',
      name: '在线漫画',
      origin: 'https://comic.example.com',
      bookType: BookType.image,
      durChapterIndex: 1,
      durChapterPos: 0,
    );

    await tester.pumpWidget(harness(book: book, api: api));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(observer.lastName, AppRoutes.readerComic);
    expect(observer.lastArguments, book.bookUrl);
  });

  testWidgets('开关关闭：在线图片书 → /reader（文本阅读器降级，走 openBook）',
      (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: false});
    final api = MockRustApi();
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    const book = Book(
      bookUrl: 'https://comic.example.com/2',
      name: '在线漫画B',
      origin: 'https://comic.example.com',
      bookType: BookType.image,
      durChapterIndex: 1,
      durChapterPos: 0,
    );
    final reader = _RecordingReaderNotifier();

    await tester.pumpWidget(harness(book: book, api: api, readerNotifier: reader));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(observer.lastName, AppRoutes.reader);
    expect(observer.lastArguments, isNull);
    expect(reader.openedBook?.bookUrl, book.bookUrl,
        reason: '降级路径必须先经 ReaderNotifier.openBook 装载（needsReaderNotifier）');
  });

  testWidgets('开关关闭：本地 cbz（LOCAL|image=0x1040）仍 → /reader-comic',
      (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: false});
    final api = MockRustApi();
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    const book = Book(
      bookUrl: 'file:///storage/books/本地漫画.cbz',
      name: '本地漫画',
      origin: BookType.localTag,
      bookType: BookType.local | BookType.image,
      durChapterIndex: 1,
      durChapterPos: 0,
    );

    await tester.pumpWidget(harness(book: book, api: api));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(observer.lastName, AppRoutes.readerComic,
        reason: '本地漫画包不随开关降级（参考版 !isLocal 条件）');
    expect(observer.lastArguments, book.bookUrl);
  });

  testWidgets('开关关闭：普通文本书仍 → /reader（不误分流）', (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: false});
    final api = MockRustApi();
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    const book = Book(
      bookUrl: 'https://novel.example.com/1',
      name: '普通小说',
      origin: 'https://novel.example.com',
      bookType: BookType.text,
      durChapterIndex: 1,
      durChapterPos: 0,
    );
    final reader = _RecordingReaderNotifier();

    await tester.pumpWidget(harness(book: book, api: api, readerNotifier: reader));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(observer.lastName, AppRoutes.reader);
    expect(reader.openedBook?.bookUrl, book.bookUrl);
  });
}
