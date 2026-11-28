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
import 'package:flutter_legado/src/widgets/reader/reader_text_selection.dart';
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
  double fontSize = 16,
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
              fontSize: fontSize,
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

  // ===== [R49 回修 P0-1] 手柄拖拽必须按「逻辑圆心」映射，不得用原始手指坐标 =====

  testWidgets('多行页从可见圆心起手：起手不跳端点，水平拖 1 字宽只走 1 字符', (tester) async {
    // 字号 40 → 测试字体每字符 40dp（Ahem 1em），保证「1 字宽」大于
    // kPanSlop(36dp)，一次 pan 位移恰好等于一个字符宽。
    const line0 = 'ab cdefg';
    const line1 = 'xy z';
    final page = _page([
      _paragraph(
        [
          _line(text: line0, chapterStart: 0, height: 60),
          _line(text: line1, chapterStart: 8, height: 60),
        ],
        start: 0,
        end: 12,
      ),
    ]);
    await tester.pumpWidget(_host(page, fontSize: 40));
    await tester.pumpAndSettle();

    // 长按 'ab' → 选区 [0, 1]
    await tester.longPressAt(
      _globalPointAtChar(tester, line0, 0, centerOfChar: true),
    );
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelectionText, 'ab');
    final before = state.debugSelection!;
    expect(before.start, 0);
    expect(before.endInclusive, 1);

    final centers = state.debugHandleCentersGlobal();
    expect(centers, hasLength(2));
    final endCenter = centers[1];
    final lineBottom = tester.getRect(find.text(line0)).bottom;
    expect(
      endCenter.dy,
      moreOrLessEquals(lineBottom + kReaderSelectionHandleRadius, epsilon: 0.6),
      reason: '圆心 = 行底 + 7dp（多行页中必然落在下一行矩形内部）',
    );
    expect(
      endCenter.dy,
      greaterThan(lineBottom),
      reason: '前置条件：可见圆心在下一行矩形内，原始手指坐标会命中下一行',
    );

    final gesture = await tester.startGesture(endCenter);
    await tester.pump();
    expect(state.debugSelection, before, reason: '按下手柄不得改变端点（起手不落点）');

    // 水平右移恰好 1 个字宽（40dp > kPanSlop 36dp）
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();

    final after = state.debugSelection!;
    expect(
      after.endInclusive,
      before.endExclusive + 1,
      reason: '终点 pin 在末字右边界（caret = endExclusive），拖 1 字宽只前进 1 字符',
    );
    expect(
      after.endInclusive,
      lessThan(8),
      reason: '不得跨到下一行（下一行章节偏移从 8 起）',
    );
    expect(after.start, before.start, reason: '起点不受终点拖动影响');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('多行页从起点可见圆心起手：端点只在本行走，不跳到下一行', (tester) async {
    const line0 = 'ab cdefg';
    const line1 = 'xy z';
    final page = _page([
      _paragraph(
        [
          _line(text: line0, chapterStart: 0, height: 60),
          _line(text: line1, chapterStart: 8, height: 60),
        ],
        start: 0,
        end: 12,
      ),
    ]);
    await tester.pumpWidget(_host(page, fontSize: 40));
    await tester.pumpAndSettle();

    // 长按 line1 的 'xy' 后向上拖到 line0 第 1 字符 → 跨行选区 [1, 8]
    final gesture = await tester.startGesture(
      _globalPointAtChar(tester, line1, 0, centerOfChar: true),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await gesture.moveTo(_globalPointAtChar(tester, line0, 1, centerOfChar: true));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final state = _state(tester);
    final before = state.debugSelection!;
    expect(before.start, 1);
    expect(before.endInclusive, 8, reason: '前置条件：跨行选区');

    // 起点 pin 的圆心 = line0 行底 + 7dp，落在 line1 矩形内
    final startCenter = state.debugHandleCentersGlobal()[0];
    expect(
      startCenter.dy,
      moreOrLessEquals(tester.getRect(find.text(line0)).bottom + 7, epsilon: 0.6),
    );

    final drag = await tester.startGesture(startCenter);
    await tester.pump();
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();

    final after = state.debugSelection!;
    expect(after.start, 2, reason: '起点在本行内前进 1 字符（不是跳到下一行）');
    expect(after.endInclusive, 8, reason: '终点不受影响');

    await drag.up();
    await tester.pumpAndSettle();
  });

  // ===== [R49 回修 P1-1] 执行动作 / 进面板后必须清选区 =====

  testWidgets('执行浮条动作后清选区：灰块/手柄/浮条一起复位', (tester) async {
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
    final state = _state(tester);
    expect(state.debugSelectionText, 'world');
    expect(state.debugHandleCount, 2);

    await tester.tap(
      find.byKey(const ValueKey('selection-action-menu_copy')),
    );
    await tester.pumpAndSettle();

    expect(copied, ['world']);
    expect(state.debugSelection, isNull, reason: '执行动作后选区必须清空');
    expect(state.debugHandleCount, 0, reason: '手柄必须一起消失');
    expect(startHandle, findsNothing);
    expect(endHandle, findsNothing);
    expect(
      _highlightPainter(tester).debugRects(),
      isEmpty,
      reason: '灰块不得驻留（否则吞掉下一次点击）',
    );
    expect(find.byType(ReaderSelectionToolbar), findsNothing);
  });

  testWidgets('打开「更多」面板即清选区：关闭面板后不驻留灰块/手柄', (tester) async {
    const line = 'Hello world again';
    final page = _page([_paragraph([_line(text: line, chapterStart: 0)])]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(_globalPointAtChar(tester, line, 6));
    await tester.pumpAndSettle();
    final state = _state(tester);
    expect(state.debugSelectionText, 'world');

    await tester.tap(find.byKey(const ValueKey('selection-action-menu_more')));
    await tester.pumpAndSettle();

    expect(find.byType(TextSelectionPanel), findsOneWidget);
    expect(state.debugSelection, isNull, reason: '进面板即清选区（设计 §5.5）');
    expect(state.debugHandleCount, 0);
    expect(_highlightPainter(tester).debugRects(), isEmpty);

    // 关闭面板：不得重新出现灰块/手柄/浮条
    Navigator.of(tester.element(find.byType(TextSelectionPanel))).pop();
    await tester.pumpAndSettle();

    expect(find.byType(TextSelectionPanel), findsNothing);
    expect(state.debugSelection, isNull);
    expect(state.debugHandleCount, 0);
    expect(startHandle, findsNothing);
    expect(endHandle, findsNothing);
    expect(find.byType(ReaderSelectionToolbar), findsNothing);
    expect(_highlightPainter(tester).debugRects(), isEmpty);
  });

  // ===== [R49 回修 P2-1] 单字选区两只 pin 热区不得互相覆盖 =====

  testWidgets('单汉字选区：两只 pin 热区不重叠，抓起点就是起点', (tester) async {
    const line = '中文测试';
    final page = _page([_paragraph([_line(text: line, chapterStart: 10)])]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(
      _globalPointAtChar(tester, line, 1, centerOfChar: true),
    );
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelectionText, '文');

    final centers = state.debugHandleCentersGlobal();
    final startRect = state.debugStartHandleHitRect!;
    final endRect = state.debugEndHandleHitRect!;
    expect(
      startRect.right,
      lessThanOrEqualTo(endRect.left + 0.01),
      reason: '同一行内两 pin 过近时热区按最近圆心平分，不得重叠',
    );
    expect(startRect.contains(centers[0]), isTrue, reason: '起点圆在起点热区内');
    expect(endRect.contains(centers[1]), isTrue, reason: '终点圆在终点热区内');

    // 从起点圆心起手：拖的必须是起点，而不是被覆盖的末端
    // （拖动侧别在越过 pan 阈值后才可判定：起手瞬间若两个热区都命中，
    //  竞技场里有两支 pan 识别器，必须先有位移才分胜负）
    final gesture = await tester.startGesture(centers[0]);
    await tester.pump();
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(state.debugDraggingSide, 'start', reason: '抓哪只 pin 就是哪只');

    final after = state.debugSelection!;
    expect(after.start, 10, reason: '起点扩到行首（中）');
    expect(after.endInclusive, 11, reason: '终点不跟着动');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  // ===== [R49 回修 P2-2] 页底末行的手柄不得被裁（圆心/热区留在正文框内） =====

  testWidgets('页底末行：终点手柄圆心内缩到正文框内且可拖', (tester) async {
    // 10 行 × 24dp = 240dp，恰好等于宿主高度：末行行底 = 正文框底
    final lines = <LineInfo>[
      for (var i = 0; i < 10; i++)
        _line(text: 'line$i', chapterStart: i * 8, height: 24),
    ];
    final page = _page([_paragraph(lines, start: 0, end: 80)]);
    await tester.pumpWidget(_host(page));
    await tester.pumpAndSettle();

    await tester.longPressAt(
      _globalPointAtChar(tester, 'line9', 2, centerOfChar: true),
    );
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.debugSelectionText, 'line9');
    final before = state.debugSelection!;
    expect(before.endInclusive, 76);

    final contentRect = tester.getRect(find.byType(ReaderTextContent));
    final centers = state.debugHandleCentersGlobal();
    expect(centers, hasLength(2));
    expect(
      centers[1].dy + kReaderSelectionHandleRadius,
      lessThanOrEqualTo(contentRect.bottom + 0.01),
      reason: '页底末行 pin 的圆必须整体留在正文框内（否则被 ClipRect 裁掉）',
    );
    expect(
      state.debugEndHandleHitRect!.contains(centers[1]),
      isTrue,
      reason: '圆心必须落在自己的热区内（可抓）',
    );

    // 从内缩后的圆心起手向左拖：端点仍在本行内移动（可抓、可拖）
    final gesture = await tester.startGesture(centers[1]);
    await tester.pump();
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    final after = state.debugSelection!;
    expect(after.endInclusive, lessThan(before.endInclusive));
    expect(after.endInclusive, greaterThanOrEqualTo(72), reason: '仍在本行（末行）内');

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
