// R49 步骤2/3/4：正文长按词级起选 + 灰块 + 手柄 + 非模态浮条 Widget 测试
// — full-stack-engineer
//
// 覆盖：
// 1. 长按英文单词 → 整词选区、灰块出现、浮条作用于选区文本；
// 2. 长按中文 → 单字选区（无 ICU 词典近似）；
// 3. 首行缩进区长按 → 落到段首字符，缩进不进选区；
// 4. 长按后拖动 → 跨行字符级扩展；
// 5. selectText=false → 无选区、无浮条；
// 6. 选区不改变任何布局尺寸（行 Text rect 前后一致、行高仍取排版结果）；
// 7. pageInfo 变化 → 选区自动清除（防跨页串选）；
// 8. [步骤3] 长按后出现 2 只手柄（起点在首行 box 左端、终点在末行 box 右端）；
// 9. [步骤3] 按坐标拖起点手柄 → 选区向左扩展；
// 10.[步骤3] 按坐标拖终点手柄 → 选区向右扩展；
// 11.[步骤4] 拖手柄期间浮条收起、松手后重新弹出；
// 12.[步骤4] 复制动作得到选区文本（不是整段）；
// 13.[步骤4] 笔记动作传入章节绝对偏移（重复词第二次出现）；
// 14.[步骤4] 点击空白 → 清选区且浮条消失。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';
import 'package:flutter_legado/src/widgets/reader/text_selection_panel.dart';

const _chapterTitle = '第一章 选区测试';

const _testBook = Book(
  bookUrl: 'https://src.com/book/r49',
  name: 'R49 测试书',
  author: '作者R',
  origin: 'https://src.com',
);

LineInfo _line({
  required String text,
  required int chapterStart,
  int skip = 0,
  double height = 24,
}) {
  return LineInfo(
    words: [text],
    width: text.length * 16.0,
    height: height,
    startIndex: 0,
    endIndex: text.length,
    chapterStartIndex: chapterStart,
    highlightSkip: skip,
    highlightMapped: true,
  );
}

PageInfo _page(List<ParagraphInfo> paragraphs) => PageInfo(
  paragraphs: paragraphs,
  totalHeight: paragraphs.fold<double>(0, (sum, p) => sum + p.totalHeight),
);

ParagraphInfo _paragraph(List<LineInfo> lines, {int start = 0, int? end}) {
  return ParagraphInfo(
    lines: lines,
    totalHeight: lines.fold<double>(0, (sum, l) => sum + l.height),
    startIndex: start,
    endIndex:
        end ??
        start + lines.fold<int>(0, (sum, l) => sum + l.words.join('').length),
    chapterParagraphIndex: 1,
    isParagraphEnd: true,
  );
}

Widget _host(
  PageInfo pageInfo, {
  bool selectText = true,
  double width = 320,
  double height = 240,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: ReaderTextContent(
              pageInfo: pageInfo,
              fontSize: 16,
              lineHeight: 1.5,
              paragraphSpacing: 8,
              textColor: Colors.black,
              selectText: selectText,
              chapterIndex: 0,
              chapterTitle: _chapterTitle,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 带书籍/章节上下文的宿主（笔记/书签等动作需要 readerNotifier 状态）
Widget _hostWithState(
  PageInfo pageInfo, {
  required ReaderState state,
  BookApi? api,
  double width = 320,
  double height = 240,
}) {
  return ProviderScope(
    overrides: [
      bookApiProvider.overrideWithValue(api ?? MockBookApi()),
      readerNotifierProvider.overrideWith(() => _FixedReaderNotifier(state)),
    ],
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: ReaderTextContent(
              pageInfo: pageInfo,
              fontSize: 16,
              lineHeight: 1.5,
              paragraphSpacing: 8,
              textColor: Colors.black,
              selectText: true,
              chapterIndex: 0,
              chapterTitle: _chapterTitle,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 固定阅读状态（避开真实 ReaderNotifier 的异步加载）
class _FixedReaderNotifier extends ReaderNotifier {
  _FixedReaderNotifier(this._state);

  final ReaderState _state;

  @override
  ReaderState build() => _state;
}

ReaderState _readerState(String content) => ReaderState(
  currentBook: _testBook,
  chapters: [
    BookChapter(
      url: 'u0',
      title: _chapterTitle,
      index: 0,
      bookUrl: _testBook.bookUrl,
    ),
  ],
  currentChapterIndex: 0,
  chapterContent: content,
);

/// 某行文本内指定字符边界的全局坐标（用真实 RenderParagraph 定位，
/// 不依赖测试字体的具体度量）
Offset _globalPointAtChar(
  WidgetTester tester,
  String text,
  int charOffset, {
  bool centerOfChar = false,
}) {
  final finder = find.text(text);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  var local = paragraph.getOffsetForCaret(
    TextPosition(offset: charOffset),
    Rect.zero,
  );
  if (centerOfChar) {
    final next = paragraph.getOffsetForCaret(
      TextPosition(offset: charOffset + 1),
      Rect.zero,
    );
    // 取字符盒内偏左 35% 处，避免正好落在两字符中点被舍入到后一个字符
    local = Offset(local.dx + (next.dx - local.dx) * 0.35, local.dy);
  }
  final point = local + Offset(0, paragraph.size.height / 2);
  return paragraph.localToGlobal(point);
}

ReaderSelectionHighlightPainter _highlightPainter(WidgetTester tester) {
  final customPaint = tester.widget<CustomPaint>(
    find.byKey(const ValueKey('reader-selection-highlight')),
  );
  return customPaint.painter! as ReaderSelectionHighlightPainter;
}

ReaderTextContentState _state(WidgetTester tester) {
  return tester.state<ReaderTextContentState>(find.byType(ReaderTextContent));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('长按英文单词：整词选区 + 灰块出现 + 浮条作用于选区', (tester) async {
    final page = _page([
      _paragraph([_line(text: 'Hello world', chapterStart: 0)]),
    ]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    expect(_state(tester).debugSelection, isNull);
    expect(_highlightPainter(tester).debugRects(), isEmpty);

    // 长按 'world' 的 w（offset 6）
    final point = _globalPointAtChar(tester, 'Hello world', 6);
    await tester.longPressAt(point);
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection, isNotNull);
    expect(state.debugSelection!.start, 6);
    expect(state.debugSelection!.endInclusive, 10);
    expect(state.debugSelectionText, 'world');

    // 灰块出现且落在文字行内
    final rects = _highlightPainter(tester).debugRects();
    expect(rects, isNotEmpty);
    final textRect = tester.getRect(find.text('Hello world'));
    expect(
      rects.every(
        (r) =>
            r.left >= textRect.left - 1 &&
            r.right <= textRect.right + 1 &&
            r.top >= textRect.top - 1 &&
            r.bottom <= textRect.bottom + 1,
      ),
      isTrue,
      reason: '灰块应覆盖行内选中字形，不得越出渲染行',
    );

    // [R49 阶段B] 浮条动作作用于选区文本；段落上下文仍保留给「更多」面板
    final toolbar = tester.widget<ReaderSelectionToolbar>(
      find.byType(ReaderSelectionToolbar),
    );
    expect(toolbar.text, 'Hello world', reason: '段落上下文（更多面板用）');
    expect(toolbar.selectedText, 'world', reason: '动作作用文本 = 选区');
    expect(toolbar.selectionStartChapterPos, 6);
    expect(toolbar.selectionEndChapterPos, 11);
  });

  testWidgets('长按中文：单字选区（无 ICU 词典近似）', (tester) async {
    final page = _page([
      _paragraph([_line(text: '中文测试', chapterStart: 10)]),
    ]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    final point = _globalPointAtChar(tester, '中文测试', 1, centerOfChar: true);
    await tester.longPressAt(point);
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection, isNotNull);
    expect(state.debugSelection!.start, 11);
    expect(state.debugSelection!.endInclusive, 11);
    expect(state.debugSelectionText, '文');
  });

  testWidgets('首行缩进区：落到段首字符，缩进不进选区', (tester) async {
    final page = _page([
      _paragraph(
        [_line(text: '　　正文', chapterStart: 20, skip: 2)],
        start: 20,
        end: 22,
      ),
    ]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    // 长按缩进区（第 0 个全角空格）
    final point = _globalPointAtChar(tester, '　　正文', 0, centerOfChar: true);
    await tester.longPressAt(point);
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection, isNotNull);
    expect(state.debugSelection!.start, 20);
    expect(state.debugSelection!.endInclusive, 20);
    expect(state.debugSelectionText, '正');
  });

  testWidgets('长按后拖动：跨行字符级扩展', (tester) async {
    final page = _page([
      _paragraph(
        [
          _line(text: 'abcdef', chapterStart: 0),
          _line(text: 'ghij', chapterStart: 6),
        ],
        start: 0,
        end: 10,
      ),
    ]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    final startPoint = _globalPointAtChar(tester, 'abcdef', 1);
    final endPoint = _globalPointAtChar(tester, 'ghij', 3, centerOfChar: true);

    final gesture = await tester.startGesture(startPoint);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(_state(tester).debugSelection, isNotNull);
    expect(_state(tester).debugSelectionText, 'abcdef');

    await gesture.moveTo(endPoint);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection, isNotNull);
    expect(state.debugSelection!.start, 0);
    expect(state.debugSelection!.endInclusive, 9);
    expect(state.debugSelectionText, 'abcdefghij');
    expect(
      _highlightPainter(tester).debugRects().length,
      greaterThanOrEqualTo(2),
    );
  });

  testWidgets('selectText=false：长按无选区、无浮条', (tester) async {
    final page = _page([
      _paragraph([_line(text: 'Hello world', chapterStart: 0)]),
    ]);
    await tester.pumpWidget(_host(page, selectText: false));
    await tester.pumpAndSettle();

    final point = _globalPointAtChar(tester, 'Hello world', 1);
    await tester.longPressAt(point);
    await tester.pumpAndSettle();

    expect(_state(tester).debugSelection, isNull);
    expect(_highlightPainter(tester).debugRects(), isEmpty);
    expect(find.byType(ReaderSelectionToolbar), findsNothing);
  });

  testWidgets('选区不改变布局：文字 rect 与行高前后一致', (tester) async {
    final page = _page([
      _paragraph([
        _line(text: 'Hello world', chapterStart: 0, height: 24),
        _line(text: 'second line', chapterStart: 12, height: 24),
      ]),
    ]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    final beforeFirst = tester.getRect(find.text('Hello world'));
    final beforeSecond = tester.getRect(find.text('second line'));

    final point = _globalPointAtChar(tester, 'Hello world', 6);
    await tester.longPressAt(point);
    await tester.pumpAndSettle();
    expect(_state(tester).debugSelection, isNotNull);

    final afterFirst = tester.getRect(find.text('Hello world'));
    final afterSecond = tester.getRect(find.text('second line'));
    expect(afterFirst, beforeFirst, reason: '选区层不得改变行位置/尺寸');
    expect(afterSecond, beforeSecond, reason: '选区层不得改变行位置/尺寸');
    expect(afterFirst.height, 24, reason: '行高仍取 line.height');
    expect(afterSecond.height, 24, reason: '行高仍取 line.height');
  });

  testWidgets('pageInfo 变化：选区自动清除', (tester) async {
    final firstPage = _page([
      _paragraph([_line(text: 'Hello world', chapterStart: 0)]),
    ]);
    await tester.pumpWidget(_host(firstPage));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, 'Hello world', 6));
    await tester.pumpAndSettle();
    expect(_state(tester).debugSelection, isNotNull);

    final secondPage = _page([
      _paragraph([_line(text: 'Next page', chapterStart: 0)]),
    ]);
    await tester.pumpWidget(_host(secondPage));
    await tester.pumpAndSettle();

    expect(_state(tester).debugSelection, isNull);
    expect(_highlightPainter(tester).debugRects(), isEmpty);
  });

  // ===== 步骤 3：手柄绘制 + 拖拽 =====

  final startHandle = find.byKey(
    const ValueKey('reader-selection-handle-start'),
  );
  final endHandle = find.byKey(
    const ValueKey('reader-selection-handle-end'),
  );

  testWidgets('长按后出现 2 只 pin 手柄（起点首行左端 / 终点末行右端）', (tester) async {
    final page = _page([
      _paragraph([_line(text: 'Hello world', chapterStart: 0)]),
    ]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    expect(startHandle, findsNothing, reason: '无选区时不得有手柄');
    expect(endHandle, findsNothing);

    await tester.longPressAt(_globalPointAtChar(tester, 'Hello world', 6));
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelectionText, 'world');
    expect(state.debugHandleCount, 2);
    expect(find.byKey(const ValueKey('reader-selection-handles')), findsOneWidget);
    expect(startHandle, findsOneWidget);
    expect(endHandle, findsOneWidget);

    // 圆心挂在行底下方 7dp；起点 = 首个相交 box 左端、终点 = 末个 box 右端
    final textRect = tester.getRect(find.text('Hello world'));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('Hello world'),
    );
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 6, extentOffset: 11),
    );
    final expectedStartX = paragraph
        .localToGlobal(boxes.first.toRect().topLeft)
        .dx;
    final expectedEndX = paragraph
        .localToGlobal(boxes.last.toRect().bottomRight)
        .dx;
    final centers = state.debugHandleCentersGlobal();
    expect(centers, hasLength(2));
    expect(
      centers[0].dy,
      moreOrLessEquals(textRect.bottom + 7, epsilon: 0.6),
      reason: '空心圆圆心 = 行底 + 半径 7dp',
    );
    expect(
      centers[1].dy,
      moreOrLessEquals(textRect.bottom + 7, epsilon: 0.6),
    );
    expect(
      centers[0].dx,
      moreOrLessEquals(expectedStartX, epsilon: 0.6),
      reason: '起点手柄 = 首个选中 box 左端',
    );
    expect(
      centers[1].dx,
      moreOrLessEquals(expectedEndX, epsilon: 0.6),
      reason: '终点手柄 = 末个选中 box 右端',
    );

    // 手柄热区 28dp 胶囊（不改变任何布局尺寸）
    final startRect = state.debugStartHandleHitRect!;
    final endRect = state.debugEndHandleHitRect!;
    expect(startRect.width, 56, reason: '热区 = 2 × 28dp');
    expect(endRect.width, 56);
    expect(
      startRect.height,
      moreOrLessEquals(24 + 7 + 28 * 2, epsilon: 0.6),
      reason: '热区覆盖行框 24 + 圆半径 7 + 上下各 28dp',
    );
  });

  testWidgets('拖起点手柄向左：选区扩展到行首', (tester) async {
    const line = 'Hello world again';
    final page = _page([_paragraph([_line(text: line, chapterStart: 0)])]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, line, 6));
    await tester.pumpAndSettle();
    expect(_state(tester).debugSelectionText, 'world');
    expect(startHandle, findsOneWidget);

    final from = tester.getCenter(startHandle);
    final to = _globalPointAtChar(tester, line, 0, centerOfChar: true);
    final gesture = await tester.startGesture(from);
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection!.start, 0);
    expect(state.debugSelection!.endInclusive, 10);
    expect(state.debugSelectionText, 'Hello world');
  });

  testWidgets('拖终点手柄向右：选区扩展到行尾单词', (tester) async {
    const line = 'Hello world again';
    final page = _page([_paragraph([_line(text: line, chapterStart: 0)])]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, line, 6));
    await tester.pumpAndSettle();
    expect(_state(tester).debugSelectionText, 'world');
    expect(endHandle, findsOneWidget);

    final from = tester.getCenter(endHandle);
    final to = _globalPointAtChar(tester, line, 16, centerOfChar: true);
    final gesture = await tester.startGesture(from);
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection!.start, 6);
    expect(state.debugSelection!.endInclusive, 16);
    expect(state.debugSelectionText, 'world again');
  });

  testWidgets('拖手柄期间浮条收起，松手后重新弹出', (tester) async {
    const line = 'Hello world again';
    final page = _page([_paragraph([_line(text: line, chapterStart: 0)])]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, line, 6));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderSelectionToolbar), findsOneWidget);
    expect(_state(tester).debugToolbarVisible, isTrue);

    final from = tester.getCenter(endHandle);
    final gesture = await tester.startGesture(from);
    await tester.pump();
    // 越过 pan 阈值（kPanSlop = 2×kTouchSlop）：手柄起手 → 收起浮条
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(
      find.byType(ReaderSelectionToolbar),
      findsNothing,
      reason: '手柄拖拽期间浮条必须收起（否则挡住手柄/抢手势）',
    );
    expect(_state(tester).debugSelection, isNotNull, reason: '选区保留');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      find.byType(ReaderSelectionToolbar),
      findsOneWidget,
      reason: '松手后按新选区重新弹出浮条',
    );
    expect(_state(tester).debugToolbarVisible, isTrue);
  });

  testWidgets('「更多」面板默认操作对象为字符级选区（不是整段）', (tester) async {
    const line = 'Hello world again';
    final page = _page([_paragraph([_line(text: line, chapterStart: 0)])]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, line, 6));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('selection-action-menu_more')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextSelectionPanel), findsOneWidget);
    expect(
      find.text('5 字'),
      findsOneWidget,
      reason: '面板打开即按选区（world = 5 字），而不是整段 17 字',
    );
  });

  // ===== 步骤 4：浮条接入选区文本 / 笔记绝对偏移 =====

  testWidgets('复制动作得到选区文本（不是整段）', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map;
          copied.add(args['text']! as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const line = 'Hello world again';
    final page = _page([_paragraph([_line(text: line, chapterStart: 0)])]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, line, 6));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('selection-action-menu_copy')),
    );
    await tester.pumpAndSettle();

    expect(copied, ['world'], reason: '复制内容必须是选区而不是整段');
    expect(find.byType(ReaderSelectionToolbar), findsNothing, reason: '执行动作后收起');
  });

  testWidgets('笔记动作传入章节绝对偏移（重复词第二次出现）', (tester) async {
    // 渲染文本含 2 个全角缩进；两个 'world' 的章节偏移分别是 100 / 110
    const paragraphText = '　　world and world';
    final page = _page([
      _paragraph(
        [_line(text: paragraphText, chapterStart: 100, skip: 2)],
        start: 100,
        end: 115,
      ),
    ]);
    final api = MockBookApi();
    await tester.pumpWidget(
      _hostWithState(page, state: _readerState(paragraphText), api: api),
    );
    await tester.pumpAndSettle();

    // 长按第二个 'world'（渲染文本下标 12 起；章节偏移 110）
    await tester.longPressAt(
      _globalPointAtChar(tester, paragraphText, 13, centerOfChar: true),
    );
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection!.start, 110, reason: '第二次出现应在 110');
    expect(state.debugSelectionText, 'world');
    expect(
      tester
          .widget<ReaderSelectionToolbar>(find.byType(ReaderSelectionToolbar))
          .selectionStartChapterPos,
      110,
    );

    await tester.tap(
      find.byKey(const ValueKey('selection-action-menu_mark')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('marking-sheet')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('marking-note-field')),
      '绝对偏移用例',
    );
    await tester.tap(find.byKey(const ValueKey('marking-save')));
    await tester.pumpAndSettle();

    final list = await api.getBookMarkingsByBook(_testBook.name, _testBook.author);
    expect(list, hasLength(1));
    final anchor = BookMarkingAnchor.tryParse(list.single.anchorJson)!;
    expect(anchor.selectedText, 'world');
    expect(
      anchor.chapterPosition,
      110,
      reason: '笔记锚点 = 章节绝对偏移（不得回落 indexOf 的第一次出现 100）',
    );
  });

  testWidgets('点击空白：清选区、手柄消失、浮条消失', (tester) async {
    final page = _page([
      _paragraph([_line(text: 'Hello world', chapterStart: 0)]),
    ]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, 'Hello world', 6));
    await tester.pumpAndSettle();
    expect(_state(tester).debugSelection, isNotNull);
    expect(startHandle, findsOneWidget);
    expect(find.byType(ReaderSelectionToolbar), findsOneWidget);

    // 行右侧空白（内容区 320×240，正文只占左上角）
    await tester.tapAt(const Offset(300, 200));
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelection, isNull);
    expect(state.debugHandleCount, 0);
    expect(startHandle, findsNothing);
    expect(endHandle, findsNothing);
    expect(find.byType(ReaderSelectionToolbar), findsNothing);
    expect(state.debugToolbarVisible, isFalse);
    expect(_highlightPainter(tester).debugRects(), isEmpty);
  });
}
