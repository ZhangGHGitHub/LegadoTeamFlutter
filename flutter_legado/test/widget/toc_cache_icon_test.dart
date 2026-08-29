import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/toc_screen.dart';

import '../mocks/mocks.dart';

/// [UI-fix v2.0.6 | 2026-08-08] Task #22：目录页章节缓存状态云图标测试 — Qoder
///
/// 对齐原版 item_chapter_list 的 iv_toc_cache：
/// - 当前阅读章（durChapterIndex）→ 对勾高亮（Symbols.check_rounded）
/// - 已缓存章（chapter_url ∈ listCachedChapterUrls）→ 实心云（Symbols.cloud_done_rounded）
/// - 未缓存章 → 空心云（Symbols.cloud_rounded）
///
/// 缓存态数据经 BookApi.listCachedChapterUrls（Rust cache_list_cached_chapter_urls
/// FFI 查询 cached_chapters 表），本测试以 mock 返回已缓存 url 集合，确定性覆盖三分支。
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

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  testWidgets('目录页每章渲染缓存态云图标（当前对勾/已缓存实心/未缓存空心）',
      (tester) async {
    // durChapterIndex 默认 0 → 第一章为当前阅读章（对勾）
    const book = Book(
      bookUrl: 'https://src.com/book/1',
      name: '测试书籍',
      origin: 'https://src.com',
      originName: '测试源',
    );

    when(() => mockApi.getChapters(any())).thenAnswer((_) async => const [
          BookChapter(
              bookUrl: 'https://src.com/book/1',
              index: 0,
              title: '第一章 开端',
              url: 'https://src.com/c0'),
          BookChapter(
              bookUrl: 'https://src.com/book/1',
              index: 1,
              title: '第二章 发展',
              url: 'https://src.com/c1'),
          BookChapter(
              bookUrl: 'https://src.com/book/1',
              index: 2,
              title: '第三章 高潮',
              url: 'https://src.com/c2'),
        ]);
    // 第二章已缓存（其 chapter_url 在集合内）
    when(() => mockApi.listCachedChapterUrls(any()))
        .thenAnswer((_) async => const ['https://src.com/c1']);
    // 目录页其余 Tab / 加载链路依赖：书签、标注返回空
    // [Task #65] 书签 Tab 改用 getBookmarksByBook（契约 §2.7，台账 §5.14-2）
    when(() => mockApi.getBookmarksByBook(any(), any()))
        .thenAnswer((_) async => const []);
    when(() => mockApi.highlightListByBook(bookUrl: any(named: 'bookUrl')))
        .thenAnswer((_) async => '[]');

    await tester.pumpWidget(wrap(const TocScreen(book: book)));
    await tester.pumpAndSettle();

    // 当前阅读章（第一章）→ 对勾
    expect(find.byIcon(Symbols.check_rounded), findsOneWidget);
    // 已缓存章（第二章）→ 实心云
    expect(find.byIcon(Symbols.cloud_done_rounded), findsOneWidget);
    // 未缓存章（第三章）→ 空心云
    expect(find.byIcon(Symbols.cloud_rounded), findsOneWidget);
  });
}
