// R49 阶段C（设计步骤5+6）：选区态翻页门控 / 点击抑制 / 页面切换清选区
// — full-stack-engineer
//
// 覆盖设计文档 §七「第 5 步最易翻车」明确列出的三种用户可见故障：
// 1. 拖手柄时翻页（选区活跃时横向拖拽被翻页层同时消费）；
// 2. 清选区后首次拖拽不翻页（门控状态未及时复位）；
// 3. 选区态误触发下滑书签（reader_swipe_bookmark_test 覆盖的下滑手势）。
// 另覆盖：
// 4. 选区态点击空白：只清选区，不触发阅读器点击分区/菜单；
// 5. 程序化翻页（音量键/自动阅读路径）清选区；
// 6. selectText=false：无选区、无手柄、无浮条；
// 7. 滚动模式：选区可用、点击空白清选区、手柄纵向拖动优先于滚动；
// 8. 滚动回退 ReaderParagraphs：selectText=false 无长按入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';
import 'package:flutter_legado/src/widgets/reader/text_selection_panel.dart';
import 'package:flutter_legado/src/widgets/reader/turn/reader_turn_view.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/r49-turn-guard',
  name: 'R49 门控书',
  author: '作者G',
  origin: 'https://source-g.com',
);

const _chapters = [
  BookChapter(
    url: 'https://book.com/r49-turn-guard/c1',
    title: '第一章',
    index: 0,
  ),
  BookChapter(
    url: 'https://book.com/r49-turn-guard/c2',
    title: '第二章',
    index: 1,
  ),
];

/// 多页正文（每段独立成行，分页结果稳定）
final _longContent = List.filled(400, '这是用于选区门控测试的正文段落。').join('\n');

class _GuardApi extends MockRustApi {
  final List<Bookmark> added = [];
  int _nextId = 300;

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
    return added;
  }

  @override
  Future<void> deleteBookmark(int id) async {}
}

_GuardApi _stubApi() {
  final api = _GuardApi();
  when(() => api.getBookSources()).thenAnswer((_) async => const []);
  when(() => api.getConfig(any())).thenAnswer((_) async => '');
  when(() => api.getBook(any())).thenAnswer((_) async => _book);
  when(() => api.getBookmarksByBook(any(), any())).thenAnswer((_) async => []);
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
  return api;
}

void _mockPrefs({bool selectText = true, bool swipeToAddBookmark = true}) {
  SharedPreferences.setMockInitialValues({
    'enableReadRecord': false,
    'selectText': selectText,
    'swipeToAddBookmark': swipeToAddBookmark,
    // 中心区 = 菜单：用于断言「选区态点击空白不得弹出菜单」
    PrefKeys.clickActionMiddleCenter: 0,
  });
}

Future<(ProviderContainer, _GuardApi)> _pumpReader(
  WidgetTester tester, {
  bool selectText = true,
}) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = _stubApi();
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

/// 当前 live 页对应的正文组件（隐藏快照页 / 相邻章预览不在 live 子树）
Finder _liveContentFinder(WidgetTester tester) {
  final index = _pageState(tester).currentPageIndex;
  return find.descendant(
    of: find.byKey(ValueKey('live-$index')),
    matching: find.byType(ReaderTextContent),
  );
}

/// 滚动模式正文组件（无 live 页 key，取首个分页 chunk）
Finder _scrollContentFinder() => find.byType(ReaderTextContent).first;

ReaderTextContentState _liveContentState(WidgetTester tester) =>
    tester.state<ReaderTextContentState>(_liveContentFinder(tester).first);

/// 正文首行第 [charOffset] 个字符的全局坐标（真实 RenderParagraph 定位，
/// 不依赖测试字体度量）
Offset _pointInFirstLine(
  WidgetTester tester, {
  int charOffset = 3,
  Finder? content,
}) {
  final root = content ?? _liveContentFinder(tester);
  final finder = find
      .descendant(of: root, matching: find.byType(RichText))
      .first;
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final local = paragraph.getOffsetForCaret(
    TextPosition(offset: charOffset),
    Rect.zero,
  );
  final next = paragraph.getOffsetForCaret(
    TextPosition(offset: charOffset + 1),
    Rect.zero,
  );
  final point = Offset(
    local.dx + (next.dx - local.dx) * 0.35,
    local.dy + paragraph.size.height / 2,
  );
  return paragraph.localToGlobal(point);
}

/// 长按正文起选（中文单字选区），返回选区文本
Future<String?> _selectFirstLine(WidgetTester tester, {Finder? content}) async {
  await tester.longPressAt(_pointInFirstLine(tester, content: content));
  await tester.pumpAndSettle();
  final state = tester.state<ReaderTextContentState>(
    (content ?? _liveContentFinder(tester)).first,
  );
  return state.debugSelectionText;
}

/// 选区态下刷新手柄热区（选区稳定后一帧同步；测试统一落一帧）
Future<void> _settleSelection(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Finder get _endHandle =>
    find.byKey(const ValueKey('reader-selection-handle-end'));

Future<void> _dragDownFrom(WidgetTester tester, Offset from, double dy) async {
  final gesture = await tester.startGesture(from);
  await tester.pump();
  await gesture.moveBy(Offset(0, dy / 2));
  await tester.pump(const Duration(milliseconds: 30));
  await gesture.moveBy(Offset(0, dy / 2));
  await tester.pump(const Duration(milliseconds: 150));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(registerFallbacks);

  testWidgets('故障1：拖手柄横向拖拽不得翻页', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _selectFirstLine(tester);
    await _settleSelection(tester);
    expect(_liveContentState(tester).debugSelection, isNotNull);
    expect(_endHandle, findsOneWidget);

    final before = _pageState(tester).currentPageIndex;
    final from = tester.getCenter(_endHandle);
    final gesture = await tester.startGesture(from);
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      _pageState(tester).currentPageIndex,
      before,
      reason: '选区活跃时拖手柄不得被裸 Listener 当作翻页',
    );
    expect(api.added, isEmpty);
    expect(
      find.byKey(const ValueKey('reader-selection-handle-end')),
      findsOneWidget,
      reason: '拖手柄后选区仍在（松手重弹浮条）',
    );
  });

  testWidgets('故障2：清选区后首次横向拖拽仍可翻页', (tester) async {
    _mockPrefs();
    final (container, _) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _selectFirstLine(tester);
    await _settleSelection(tester);
    expect(_liveContentState(tester).debugSelection, isNotNull);

    // 点击正文中部（默认中心区=菜单）：清选区，本次点击不得弹菜单
    final content = _liveContentFinder(tester).first;
    await tester.tapAt(tester.getCenter(content));
    await tester.pumpAndSettle();
    expect(_liveContentState(tester).debugSelection, isNull, reason: '空白点击清选区');
    expect(
      container.read(readerNotifierProvider).showControls,
      isFalse,
      reason: '清选区的这次点击不得触发中心区菜单',
    );

    final before = _pageState(tester).currentPageIndex;
    await tester.drag(find.byType(ReaderTurnView), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(
      _pageState(tester).currentPageIndex,
      greaterThan(before),
      reason: '清选区后第一次横向拖拽必须立即恢复翻页（门控不得粘滞）',
    );
  });

  testWidgets('故障3：选区态从手柄下滑不得添加书签', (tester) async {
    _mockPrefs();
    final (container, api) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _selectFirstLine(tester);
    await _settleSelection(tester);
    expect(_liveContentState(tester).debugSelection, isNotNull);

    await _dragDownFrom(tester, tester.getCenter(_endHandle), 120);

    expect(api.added, isEmpty, reason: '选区活跃时下滑手势归选区，不得触发下滑书签');
    expect(
      _liveContentState(tester).debugSelection,
      isNotNull,
      reason: '选区保留（手柄下拉只扩展/收缩选区）',
    );
  });

  testWidgets('选区态点击空白：只清选区，不触发九宫格菜单', (tester) async {
    _mockPrefs();
    final (container, _) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _selectFirstLine(tester);
    await _settleSelection(tester);
    expect(find.byType(ReaderSelectionToolbar), findsOneWidget);

    // 页面中部空白（位于正文块右侧、屏幕中心区=菜单）：第一次点击清选区，
    // 第二次点击恢复正常九宫格（不粘滞）
    const blankPoint = Offset(400, 600);
    await tester.tapAt(blankPoint);
    await tester.pumpAndSettle();

    expect(_liveContentState(tester).debugSelection, isNull);
    expect(_liveContentState(tester).debugHandleCount, 0);
    expect(find.byType(ReaderSelectionToolbar), findsNothing);
    expect(
      container.read(readerNotifierProvider).showControls,
      isFalse,
      reason: '清选区的点击不得触发阅读器点击分区',
    );

    await tester.tapAt(blankPoint);
    await tester.pump();
    expect(
      container.read(readerNotifierProvider).showControls,
      isTrue,
      reason: '清选区后下一次点击必须正常分发九宫格动作',
    );
  });

  testWidgets('程序化翻页（音量键/自动阅读路径）清除选区', (tester) async {
    _mockPrefs();
    final (container, _) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _selectFirstLine(tester);
    await _settleSelection(tester);
    expect(_liveContentState(tester).debugSelection, isNotNull);

    final before = _pageState(tester).currentPageIndex;
    _pageState(tester).nextPageOrChapter();
    await tester.pumpAndSettle();

    expect(_pageState(tester).currentPageIndex, greaterThan(before));
    expect(
      find.byKey(const ValueKey('reader-selection-handle-end')),
      findsNothing,
      reason: '翻页后旧页选区/手柄不得残留',
    );
    expect(_liveContentState(tester).debugSelection, isNull);
  });

  testWidgets('selectText=false：长按无选区、无手柄、无浮条', (tester) async {
    _mockPrefs(selectText: false);
    final (container, _) = await _pumpReader(tester, selectText: false);
    addTearDown(container.dispose);

    await tester.longPressAt(_pointInFirstLine(tester));
    await tester.pumpAndSettle();

    expect(_liveContentState(tester).debugSelection, isNull);
    expect(
      find.byKey(const ValueKey('reader-selection-handle-start')),
      findsNothing,
    );
    expect(find.byType(ReaderSelectionToolbar), findsNothing);
    expect(_pageState(tester).currentPageIndex, 0, reason: '长按不得翻页');
  });

  testWidgets('换章清除选区（章节内容变化重建正文）', (tester) async {
    _mockPrefs();
    final (container, _) = await _pumpReader(tester);
    addTearDown(container.dispose);

    await _selectFirstLine(tester);
    await _settleSelection(tester);
    expect(_liveContentState(tester).debugSelection, isNotNull);

    await container.read(readerNotifierProvider.notifier).nextChapter();
    await tester.pumpAndSettle();

    expect(
      container.read(readerNotifierProvider).currentChapterIndex,
      1,
      reason: '已进入第二章',
    );
    expect(
      find.byKey(const ValueKey('reader-selection-handle-end')),
      findsNothing,
      reason: '换章后不得残留上一章选区/手柄',
    );
    expect(_liveContentState(tester).debugSelection, isNull);
  });

  testWidgets('滚动回退 ReaderParagraphs：selectText=false 无长按入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 240,
              child: ReaderParagraphs(
                content: '第一段正文\n第二段正文',
                fontSize: 16,
                lineHeight: 1.5,
                paragraphSpacing: 8,
                textColor: Colors.black,
                selectText: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('第一段正文'));
    await tester.pumpAndSettle();

    expect(
      find.byType(TextSelectionPanel),
      findsNothing,
      reason: '回退渲染保持段落级入口，但 selectText=false 时必须完全关闭',
    );
  });

  testWidgets('滚动模式：长按起选可用，点击空白清选区且不弹菜单', (tester) async {
    _mockPrefs();
    final (container, _) = await _pumpReader(tester);
    addTearDown(container.dispose);

    container
        .read(readerNotifierProvider.notifier)
        .updatePageTurnMode(PageTurnMode.scroll);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderTurnView), findsNothing);

    final scrollContent = _scrollContentFinder();
    await _selectFirstLine(tester, content: scrollContent);
    final state = tester.state<ReaderTextContentState>(scrollContent);
    expect(state.debugSelection, isNotNull, reason: '滚动模式分页 chunk 同样支持选区');

    await tester.tapAt(const Offset(400, 600));
    await tester.pumpAndSettle();
    expect(state.debugSelection, isNull);
    expect(container.read(readerNotifierProvider).showControls, isFalse);
  });

  testWidgets('滚动模式：手柄纵向拖动优先于 Scrollable（不滚动页面）', (tester) async {
    _mockPrefs();
    final (container, _) = await _pumpReader(tester);
    addTearDown(container.dispose);

    container
        .read(readerNotifierProvider.notifier)
        .updatePageTurnMode(PageTurnMode.scroll);
    await tester.pumpAndSettle();

    final scrollContent = _scrollContentFinder();
    await _selectFirstLine(tester, content: scrollContent);
    await _settleSelection(tester);
    final contentState = tester.state<ReaderTextContentState>(scrollContent);
    final beforeSelection = contentState.debugSelection!;

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final beforeOffset = scrollable.position.pixels;
    final endHandle = find.byKey(const ValueKey('reader-selection-handle-end'));
    expect(endHandle, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(endHandle));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 48));
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      scrollable.position.pixels,
      moreOrLessEquals(beforeOffset, epsilon: 0.5),
      reason: '手柄热区内的纵向拖动必须由手柄消费，不得滚动正文',
    );
    expect(endHandle, findsOneWidget, reason: '拖动后选区仍在');
    expect(
      contentState.debugSelection!.endInclusive,
      greaterThan(beforeSelection.endInclusive),
      reason: '纵向拖动手柄应扩展选区到后续行（而不是被滚动吞掉）',
    );

    // 对照：空白处拖动仍可正常滚动（证明上一步不是整页不可滚动）
    await tester.drag(find.byType(ReaderPageView), const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(
      scrollable.position.pixels,
      greaterThan(beforeOffset),
      reason: '选区清除后正文空白拖动必须恢复滚动',
    );
  });
}
