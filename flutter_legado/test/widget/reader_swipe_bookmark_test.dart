// [批4d] 阅读器下滑书签 / 角标 / 顶栏书签接线测试
//
// 覆盖：
// 1. 进入阅读器按书名+作者 loadByBook，既有书签页显示角标；
// 2. 分页模式下滑 ≥80dp 添加书签（chapterPos=页首偏移），再次下滑删除；
// 3. 边界：<80dp、横向拖动（归翻页）、菜单展开、滚动模式、开关关闭；
// 4. 角标：size=0 隐藏、自定义图缺失回落默认；
// 5. 顶栏添加书签使用当前屏页首（非章首）；
// 6. 同页切书按新书键重新加载。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/widgets/reader/reader_bookmark_badge.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';
import 'package:flutter_legado/src/widgets/reader/turn/reader_turn_view.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/swipe-bookmark',
  name: '滑动书签书',
  author: '作者B',
  origin: 'https://source-b.com',
  originName: '源B',
);

const _otherBook = Book(
  bookUrl: 'https://book.com/swipe-bookmark-2',
  name: '另一本书',
  author: '作者C',
  origin: 'https://source-c.com',
  originName: '源C',
);

const _chapters = [
  BookChapter(
    url: 'https://book.com/swipe-bookmark/c1',
    title: '第一章',
    index: 0,
  ),
  BookChapter(
    url: 'https://book.com/swipe-bookmark/c2',
    title: '第二章',
    index: 1,
  ),
];

/// 足够多页的正文（用于翻到第 2 页验证页首偏移非 0）
final _longContent = List.filled(400, '这是用于分页测试的正文段落。').join('\n');

class _BookmarkApi extends MockRustApi {
  _BookmarkApi(this.stored);

  final List<Bookmark> stored;
  final List<Bookmark> added = [];
  final List<int> deleted = [];
  int _nextId = 100;

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => _chapters;

  @override
  Future<String> getChapterContentFull(
    String bookUrl,
    int chapterIndex,
  ) async => _longContent;

  @override
  Future<String> getChapterContent(String bookUrl, int chapterIndex) async =>
      '';

  @override
  Future<Bookmark> addBookmark(Bookmark bookmark) async {
    final added = bookmark.copyWith(id: _nextId++);
    this.added.add(added);
    stored.insert(0, added);
    return added;
  }

  @override
  Future<void> deleteBookmark(int id) async {
    deleted.add(id);
    stored.removeWhere((b) => b.id == id);
  }
}

_BookmarkApi _stubApi(List<Bookmark> stored) {
  final api = _BookmarkApi(stored);
  when(() => api.getBookSources()).thenAnswer((_) async => const []);
  when(() => api.getConfig(any())).thenAnswer((_) async => '');
  when(() => api.getBook(any())).thenAnswer((_) async => _book);
  when(() => api.getBookmarksByBook(any(), any())).thenAnswer((
    invocation,
  ) async {
    final name = invocation.positionalArguments[0] as String;
    final author = invocation.positionalArguments[1] as String;
    return stored
        .where((b) => b.bookName == name && b.bookAuthor == author)
        .toList();
  });
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
  return api;
}

void _mockPrefs({
  bool swipeToAddBookmark = true,
  int bookmarkBadgeSize = 10,
  String bookmarkBadgeImage = '',
}) {
  SharedPreferences.setMockInitialValues({
    'enableReadRecord': false,
    'swipeToAddBookmark': swipeToAddBookmark,
    'bookmarkBadgeSize': bookmarkBadgeSize,
    'bookmarkBadgeImage': bookmarkBadgeImage,
  });
}

Future<(ProviderContainer, _BookmarkApi)> _pumpReader(
  WidgetTester tester, {
  List<Bookmark>? stored,
}) async {
  final api = _stubApi(stored ?? []);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: const MaterialApp(home: ReaderScreen()),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ReaderScreen)),
  );
  await container.read(readerNotifierProvider.notifier).openBook(_book);
  await tester.pumpAndSettle();
  return (container, api);
}

ReaderPageViewState _pageState(WidgetTester tester) =>
    tester.state<ReaderPageViewState>(find.byType(ReaderPageView));

Future<void> _dragDown(WidgetTester tester, double dy) async {
  await tester.drag(find.byType(ReaderTurnView), Offset(0, dy));
  await tester.pumpAndSettle();
}

Future<void> _turnToNextPage(WidgetTester tester) async {
  final size = tester.getSize(find.byType(ReaderScreen));
  final origin = tester.getTopLeft(find.byType(ReaderScreen));
  await tester.tapAt(origin + Offset(size.width * 0.85, size.height * 0.5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('进入阅读器按书名+作者加载既有书签并显示角标', (tester) async {
    _mockPrefs();
    final stored = [
      const Bookmark(
        id: 7,
        bookName: '滑动书签书',
        bookAuthor: '作者B',
        chapterIndex: 0,
        chapterPos: 0,
        chapterName: '第一章',
      ),
    ];
    final (container, api) = await _pumpReader(tester, stored: stored);
    addTearDown(container.dispose);

    verify(() => api.getBookmarksByBook('滑动书签书', '作者B')).called(1);
    expect(
      find.byKey(const ValueKey('bookmark-badge-default')),
      findsWidgets,
      reason: '当前页范围含 chapterPos=0，应显示默认琥珀角标',
    );
  });

  testWidgets('下滑 ≥80dp 添加书签（页首偏移）→ 再次下滑删除', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    // 先翻到第 2 页，验证 chapterPos 取当前屏页首而非章首
    await _turnToNextPage(tester);
    final pageState = _pageState(tester);
    expect(pageState.currentPageIndex, greaterThan(0), reason: '应翻到第 2 页');
    final expectedPos = pageState.currentPageStartPos;
    expect(expectedPos, greaterThan(0), reason: '第 2 页页首偏移应大于 0');
    final expectedText = pageState.currentPageStartText;
    expect(expectedText.trim(), isNotEmpty);

    await _dragDown(tester, 120);
    expect(api.added, hasLength(1), reason: '≥80dp 松手添加书签');
    final added = api.added.single;
    expect(added.bookName, '滑动书签书');
    expect(added.bookAuthor, '作者B');
    expect(added.chapterIndex, 0);
    expect(added.chapterPos, expectedPos, reason: '书签落在当前屏页首');
    expect(added.bookText, expectedText, reason: '摘要取页首可见行正文');
    expect(added.content, '', reason: 'content 是用户备注，不得写正文');
    expect(
      find.byKey(const ValueKey('bookmark-badge-default')),
      findsWidgets,
      reason: '新增书签后本页显示角标',
    );

    // 同屏再次下滑 → 取消本页书签
    await _dragDown(tester, 120);
    expect(api.deleted, [added.id], reason: '再次下滑删除本屏书签');
    expect(
      find.byKey(const ValueKey('bookmark-badge-default')),
      findsNothing,
      reason: '删除后角标消失',
    );
  });

  testWidgets('未达 80dp 不添加书签', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _dragDown(tester, 60);
    expect(api.added, isEmpty, reason: '未达激活阈值只回弹');
  });

  testWidgets('下拉达阈值显示顶部提示；回移后松手按最终位移不添加', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    AnimatedOpacity hintOpacity() => tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text('松手以添加书签'),
        matching: find.byType(AnimatedOpacity),
      ),
    );

    final center = tester.getCenter(find.byType(ReaderTurnView));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 150));
    expect(hintOpacity().opacity, 1, reason: '≥80dp 显示「松手以添加书签」');

    // 回移到阈值内：抬手必须用最终位移（20dp）判定，不得切换
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(hintOpacity().opacity, 0, reason: '回移后提示隐藏');
    await gesture.up();
    await tester.pumpAndSettle();

    expect(api.added, isEmpty, reason: '最终位移 20dp < 80dp，不添加书签');
    expect(
      tester.getSize(find.byType(ReaderTurnView)),
      isNot(Size.zero),
      reason: '回弹后页面仍正常渲染',
    );
  });

  testWidgets('横向拖动归翻页，不添加书签', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await tester.drag(find.byType(ReaderTurnView), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(api.added, isEmpty, reason: '横向手势不得触发书签');
    expect(
      _pageState(tester).currentPageIndex,
      greaterThan(0),
      reason: '横向手势仍走翻页',
    );
  });

  testWidgets('菜单展开时禁用手势', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    container.read(readerNotifierProvider.notifier).toggleControls();
    await tester.pumpAndSettle();

    final turn = tester.widget<ReaderTurnView>(find.byType(ReaderTurnView));
    expect(turn.pullBookmarkEnabled, isFalse, reason: '菜单展开即关闭下拉手势');
    await _dragDown(tester, 120);
    expect(api.added, isEmpty);
  });

  testWidgets('滚动模式禁用手势（无下拉书签表面）', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    container
        .read(readerNotifierProvider.notifier)
        .updatePageTurnMode(PageTurnMode.scroll);
    await tester.pumpAndSettle();

    expect(find.byType(ReaderTurnView), findsNothing, reason: '滚动模式不建翻页视图');
    await tester.drag(find.byType(ReaderPageView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(api.added, isEmpty, reason: '滚动模式不得触发书签');
  });

  testWidgets('开关关闭时不下滑添加', (tester) async {
    _mockPrefs(swipeToAddBookmark: false);
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    final turn = tester.widget<ReaderTurnView>(find.byType(ReaderTurnView));
    expect(turn.pullBookmarkEnabled, isFalse);
    await _dragDown(tester, 120);
    expect(api.added, isEmpty);
  });

  testWidgets('角标大小 0 隐藏；自定义图缺失回落默认', (tester) async {
    _mockPrefs(bookmarkBadgeSize: 0);
    final stored = [
      const Bookmark(
        id: 8,
        bookName: '滑动书签书',
        bookAuthor: '作者B',
        chapterIndex: 0,
        chapterPos: 0,
      ),
    ];
    final (container, _) = await _pumpReader(tester, stored: stored);
    addTearDown(container.dispose);

    expect(
      find.byType(ReaderBookmarkBadge),
      findsNothing,
      reason: 'size=0 不渲染角标',
    );

    // 改回 10dp + 缺失的自定义图标识 → 默认书签带
    await tester.pumpWidget(const SizedBox());
    _mockPrefs(
      bookmarkBadgeImage:
          'bookmark_badges/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png',
    );
    final (container2, _) = await _pumpReader(tester, stored: stored);
    addTearDown(container2.dispose);
    expect(
      find.byKey(const ValueKey('bookmark-badge-default')),
      findsWidgets,
      reason: '文件缺失时回落默认琥珀书签带',
    );
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('顶栏添加书签使用当前屏页首（非章首）', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _turnToNextPage(tester);
    final pageState = _pageState(tester);
    final expectedPos = pageState.currentPageStartPos;
    expect(expectedPos, greaterThan(0));

    final panel = tester.widget<ReaderMenuPanel>(find.byType(ReaderMenuPanel));
    panel.onAddBookmark();
    await tester.pumpAndSettle();

    expect(api.added, hasLength(1));
    final added = api.added.single;
    expect(added.chapterPos, expectedPos);
    expect(
      added.chapterIndex,
      pageState.currentPageChapterIndex,
      reason: '章号与页偏移同源（PageView 页上下文）',
    );
    expect(
      added.chapterName,
      pageState.currentPageChapterTitle,
      reason: '章名与页偏移同源（PageView 页上下文）',
    );
    expect(added.content, '', reason: 'content 不得写入正文');
  });

  testWidgets('同页切书按新书键重新加载书签', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await container.read(readerNotifierProvider.notifier).openBook(_otherBook);
    await tester.pumpAndSettle();

    verify(() => api.getBookmarksByBook('另一本书', '作者C')).called(1);
    expect(
      find.byKey(const ValueKey('bookmark-badge-default')),
      findsNothing,
      reason: '新书无书签，不残留旧书角标',
    );
  });
}
