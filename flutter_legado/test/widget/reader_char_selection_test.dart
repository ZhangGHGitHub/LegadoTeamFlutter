// R49 阶段A 步骤2：正文长按词级起选 + 灰块绘制 Widget 测试
// — full-stack-engineer
//
// 覆盖：
// 1. 长按英文单词 → 整词选区、灰块出现、浮条仍按整段弹出（本阶段兼容路径）；
// 2. 长按中文 → 单字选区（无 ICU 词典近似）；
// 3. 首行缩进区长按 → 落到段首字符，缩进不进选区；
// 4. 长按后拖动 → 跨行字符级扩展；
// 5. selectText=false → 无选区、无浮条；
// 6. 选区不改变任何布局尺寸（行 Text rect 前后一致、行高仍取排版结果）；
// 7. pageInfo 变化 → 选区自动清除（防跨页串选）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';
import 'package:flutter_legado/src/widgets/reader/text_selection_panel.dart';

const _chapterTitle = '第一章 选区测试';

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

  testWidgets('长按英文单词：整词选区 + 灰块出现 + 浮条仍传整段', (tester) async {
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

    // 本阶段浮条行为保持现状：仍传整段文本
    final toolbar = tester.widget<ReaderSelectionToolbar>(
      find.byType(ReaderSelectionToolbar),
    );
    expect(toolbar.text, 'Hello world');
    expect(toolbar.chapterPos, 0);
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
}
