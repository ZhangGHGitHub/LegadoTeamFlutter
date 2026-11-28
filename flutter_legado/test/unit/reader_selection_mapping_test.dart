// R49 阶段A 步骤1：字符级选区模型与行级映射纯函数单测 — full-stack-engineer
//
// 覆盖（对齐设计文档 §5.2 映射规则）：
// 1. 纯文本行：行内 ↔ 章节偏移、半开区间截断；
// 2. 首行缩进：缩进列落到段首，不进入选中文本；
// 3. 悬挂缩进：hangingWidth > 0 不影响映射口径；
// 4. CRLF：段落偏移按 `\r\n` 推进，选中文本不含 `\r`；
// 5. 行内图片：占位符逐字符映射、`<img>` 标签内部偏移落到图片后字符、
//    复制文本剔除占位符；
// 6. 跨行、跨段选区与文本提取（段间补 `\n`）；
// 7. 词边界：中文/英文/数字/标点/连接符/代理对/组合附加符号。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/reader_inline_image.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_selection.dart';

const _config = ParagraphConfig(
  fontSize: 16,
  lineHeight: 1.5,
  paragraphSpacing: 8,
  indent: 32,
  indentCount: 2,
  backgroundColor: Colors.white,
  textColor: Colors.black,
);

ParagraphConfig _configWith({bool hanging = false, bool indent = true}) =>
    _config.copyWith(
      indent: indent ? 32 : 0,
      indentCount: indent ? 2 : 0,
      hangingPunctuation: hanging,
    );

ParagraphLayoutEngine _engine([ParagraphConfig? config]) =>
    ParagraphLayoutEngine(
      config: config ?? _config,
      context: _FakeBuildContext(),
    );

/// 宽高足够大，保证整章落在同一页（只看分行/映射，不测分页）
List<PageInfo> _paginate(String content, {ParagraphConfig? config}) =>
    _engine(config).paginateChapter(content, 10000, 10000);

List<LineInfo> _allLines(PageInfo page) => [
  for (final para in page.paragraphs) ...para.lines,
];

LineInfo _pureLine({
  required String text,
  int chapterStart = 0,
  int skip = 0,
  double hangingWidth = 0,
}) {
  return LineInfo(
    words: [text],
    width: text.length * 16.0,
    height: 24,
    startIndex: 0,
    endIndex: text.length,
    hangingWidth: hangingWidth,
    chapterStartIndex: chapterStart,
    highlightSkip: skip,
    highlightMapped: true,
  );
}

void main() {
  group('ReaderTextSelection 端点语义（含端）', () {
    test('正向/反向选区归一化', () {
      const forward = ReaderTextSelection(anchor: 2, focus: 5);
      expect(forward.start, 2);
      expect(forward.endInclusive, 5);
      expect(forward.endExclusive, 6);
      expect(forward.length, 4);
      expect(forward.isCollapsed, isFalse);

      const backward = ReaderTextSelection(anchor: 5, focus: 2);
      expect(backward.start, 2);
      expect(backward.endInclusive, 5);
      expect(backward.endExclusive, 6);
    });

    test('单字符选区（anchor == focus）不是折叠选区', () {
      const single = ReaderTextSelection(anchor: 3, focus: 3);
      expect(single.length, 1);
      expect(single.isCollapsed, isFalse);
      expect(single.containsChapterOffset(3), isTrue);
      expect(single.containsChapterOffset(4), isFalse);
    });

    test('copyWith 保留未覆盖端点', () {
      const sel = ReaderTextSelection(anchor: 1, focus: 4);
      final moved = sel.withFocus(9);
      expect(moved.anchor, 1);
      expect(moved.focus, 9);
      expect(moved.start, 1);
      expect(moved.endExclusive, 10);
    });
  });

  group('纯文本行映射', () {
    test('缩进行：缩进列落到段首，正文线性映射', () {
      // 渲染文本 = 2 个全角缩进 + 'Hello'，正文从 local 2 开始，章节偏移 100
      final map = ReaderLineSelectionMap(
        _pureLine(text: '　　Hello', chapterStart: 100, skip: 2),
      );
      expect(map.text, '　　Hello');
      expect(map.skip, 2);
      expect(map.firstSelectableLocal, 2);
      expect(map.bodyStart, 100);
      expect(map.bodyEnd, 105);

      expect(map.localToChapter(0), 100);
      expect(map.localToChapter(1), 100);
      expect(map.localToChapter(2), 100);
      expect(map.localToChapter(3), 101);
      expect(map.localToChapter(7), 105);

      expect(map.chapterToLocal(99), -1);
      expect(map.chapterToLocal(100), 2);
      expect(map.chapterToLocal(104), 6);
      expect(map.chapterToLocal(105), -1);
    });

    test('半开区间截断：相交行返回局部区间，不相交返回 null', () {
      final map = ReaderLineSelectionMap(
        _pureLine(text: '　　Hello', chapterStart: 100, skip: 2),
      );
      expect(map.localRangeFor(100, 105), (2, 7));
      expect(map.localRangeFor(50, 100), isNull, reason: 'endExclusive == 行首');
      expect(map.localRangeFor(105, 110), isNull, reason: 'start == 行尾之后');
      expect(map.localRangeFor(50, 101), (2, 3));
      expect(map.localRangeFor(104, 105), (6, 7));
      expect(map.localRangeFor(101, 101), isNull, reason: '空区间');
    });

    test('无缩进行：local 0 即段落起点', () {
      final map = ReaderLineSelectionMap(
        _pureLine(text: 'abcde', chapterStart: 10),
      );
      expect(map.bodyStart, 10);
      expect(map.bodyEnd, 15);
      expect(map.localToChapter(0), 10);
      expect(map.chapterToLocal(10), 0);
      expect(map.localRangeFor(10, 15), (0, 5));
    });

    test('悬挂缩进行：hangingWidth 只影响绘制位置，不影响映射', () {
      final normal = ReaderLineSelectionMap(
        _pureLine(text: '“悬挂”测试', chapterStart: 0, skip: 2),
      );
      final hanging = ReaderLineSelectionMap(
        _pureLine(text: '“悬挂”测试', chapterStart: 0, skip: 2, hangingWidth: 32),
      );
      expect(normal.localToChapter(2), hanging.localToChapter(2));
      expect(normal.localToChapter(4), hanging.localToChapter(4));
      expect(normal.localRangeFor(0, 3), hanging.localRangeFor(0, 3));
    });

    test('排版引擎缩进行：skip/chapterStartIndex 与映射一致', () {
      final pages = _paginate('第一段正文内容。\n第二段正文内容。');
      final line = pages.single.paragraphs.first.lines.first;
      final map = ReaderLineSelectionMap(line);
      expect(map.skip, 2, reason: '首行缩进 2 个全角空格');
      expect(map.text.startsWith('　　'), isTrue);
      expect(map.bodyStart, 0);
      expect(map.localToChapter(2), 0);
      expect(map.localToChapter(3), 1);
      // 第二段：起始偏移 = 第一段长度 + '\n'
      final second = pages.single.paragraphs[1].lines.first;
      final secondMap = ReaderLineSelectionMap(second);
      expect(secondMap.skip, 2);
      expect(secondMap.bodyStart, '第一段正文内容。'.length + 1);
      expect(secondMap.localToChapter(2), secondMap.bodyStart);
    });

    test('排版引擎悬挂行：hangingWidth > 0 且映射仍从段首开始', () {
      final pages = _paginate(
        '“悬挂缩进”第一段。\n第二段。',
        config: _configWith(hanging: true),
      );
      final line = pages.single.paragraphs.first.lines.first;
      expect(line.hangingWidth, greaterThan(0));
      final map = ReaderLineSelectionMap(line);
      expect(map.text.startsWith('　　“'), isTrue);
      expect(map.skip, 2);
      expect(map.localToChapter(2), 0);
      expect(map.localToChapter(3), 1);
      final sel = readerSelectionForWordAt(map, 0);
      expect(sel, isNotNull);
      expect(sel!.start, 0, reason: '缩进区点击应落到段首字符');
    });
  });

  group('CRLF 与段落偏移', () {
    test('CRLF 分段：第二段偏移按 \\r\\n 推进，行文本不含 \\r', () {
      final pages = _paginate('第一段。\r\n第二段。');
      expect(pages.single.paragraphs.length, 2);
      final second = pages.single.paragraphs[1];
      // '第一段。' = 4 code units，'\r\n' = 2，第二段从 6 开始
      expect(second.startIndex, 6);
      for (final line in _allLines(pages.single)) {
        expect(line.words.join(''), isNot(contains('\r')));
      }
      final secondMap = ReaderLineSelectionMap(second.lines.first);
      expect(secondMap.bodyStart, 6);
      expect(secondMap.localToChapter(2), 6);
    });

    test('CRLF 跨段选区文本：段间补 \\n 且不含 \\r', () {
      final pages = _paginate('第一段。\r\n第二段。');
      final page = pages.single;
      final endChapter = page.paragraphs[1].endIndex;
      final selection = ReaderTextSelection(anchor: 0, focus: endChapter - 1);
      expect(readerSelectionText(page, selection), '第一段。\n第二段。');
    });
  });

  group('行内图片行映射', () {
    test('占位符逐字符映射到 <img> 标签起点，复制文本剔除占位符', () {
      const content = '前文<img src="https://c.com/selection-inline.png">后文';
      final image = parseReaderInlineImage(
        'https://c.com/selection-inline.png',
      )!;
      ReaderImageSizeCache.put(image.rawSrc, const ReaderImageSize(24, 24));
      final pages = _paginate(content);
      final lines = _allLines(pages.single);
      final line = lines.firstWhere((l) => l.inlineImages.isNotEmpty);
      final map = ReaderLineSelectionMap(line);
      final placeholderLocal = map.text.indexOf(readerImagePlaceholderChar);
      expect(placeholderLocal, map.skip + 2, reason: '缩进之后「前文」的下一字符是占位符');
      expect(map.localToChapter(placeholderLocal), 2, reason: '<img> 标签起点');
      expect(
        map.localToChapter(placeholderLocal + 1),
        greaterThan(2),
        reason: '图片后第一个字符的章节偏移大于标签起点',
      );
      expect(map.chapterToLocal(2), placeholderLocal);
      expect(map.localRangeFor(2, 3), (
        placeholderLocal,
        placeholderLocal + 1,
      ), reason: '图片占位符按 1 个字符参与选区');

      final wordSelection = readerSelectionForWordAt(map, placeholderLocal);
      expect(wordSelection, isNotNull);
      expect(wordSelection!.start, 2);
      expect(wordSelection.endInclusive, 2);
      expect(
        readerSelectionText(pages.single, wordSelection),
        '',
        reason: '占位符不进入复制文本',
      );
    });

    test('含行内图片整行选区：文字保留、占位符剔除', () {
      const content = '前文<img src="https://c.com/selection-inline2.png">后文';
      final image = parseReaderInlineImage(
        'https://c.com/selection-inline2.png',
      )!;
      ReaderImageSizeCache.put(image.rawSrc, const ReaderImageSize(24, 24));
      final pages = _paginate(content);
      final page = pages.single;
      final para = page.paragraphs.first;
      final selection = ReaderTextSelection(
        anchor: 0,
        focus: para.endIndex - 1,
      );
      expect(readerSelectionText(page, selection), '前文后文');
    });

    test('独立图片行不参与文字选区', () {
      const content = '第一段。\n<img src="https://c.com/selection-big.png">\n第三段。';
      final image = parseReaderInlineImage('https://c.com/selection-big.png')!;
      ReaderImageSizeCache.put(image.rawSrc, const ReaderImageSize(400, 300));
      final pages = _paginate(content, config: _configWith(indent: false));
      final imageLine = _allLines(
        pages.single,
      ).firstWhere((line) => line.imageLayout != null);
      final map = ReaderLineSelectionMap(imageLine);
      expect(map.isImageOnlyLine, isTrue);
      expect(map.isSelectable, isFalse);
      expect(map.localRangeFor(0, 1000), isNull);
      expect(map.chapterToLocal(imageLine.chapterStartIndex), -1);
    });
  });

  group('跨行与跨段选区', () {
    LineInfo lineOf(String text, int chapterStart) =>
        _pureLine(text: text, chapterStart: chapterStart);

    test('跨行：两行分别截断后拼接（行间无额外字符）', () {
      final paragraph = ParagraphInfo(
        lines: [lineOf('abc', 10), lineOf('defg', 13)],
        totalHeight: 48,
        startIndex: 10,
        endIndex: 17,
      );
      final page = PageInfo(paragraphs: [paragraph], totalHeight: 48);
      const selection = ReaderTextSelection(anchor: 11, focus: 14);
      expect(readerSelectionText(page, selection), 'bcde');
      expect(
        ReaderLineSelectionMap(
          paragraph.lines[0],
        ).localRangeFor(selection.start, selection.endExclusive),
        (1, 3),
      );
      expect(
        ReaderLineSelectionMap(
          paragraph.lines[1],
        ).localRangeFor(selection.start, selection.endExclusive),
        (0, 2),
      );
    });

    test('跨段：段间补 \\n，段内不补', () {
      final first = ParagraphInfo(
        lines: [lineOf('第一行', 0)],
        totalHeight: 24,
        startIndex: 0,
        endIndex: 3,
      );
      final second = ParagraphInfo(
        lines: [lineOf('第二行', 5)],
        totalHeight: 24,
        startIndex: 5,
        endIndex: 8,
      );
      final page = PageInfo(paragraphs: [first, second], totalHeight: 48);

      expect(
        readerSelectionText(
          page,
          const ReaderTextSelection(anchor: 1, focus: 6),
        ),
        '一行\n第二',
      );
      expect(
        readerSelectionText(
          page,
          const ReaderTextSelection(anchor: 5, focus: 7),
        ),
        '第二行',
        reason: '仅第二段时不应有前导换行',
      );
      expect(
        readerSelectionText(
          page,
          const ReaderTextSelection(anchor: 0, focus: 7),
        ),
        '第一行\n第二行',
      );
    });

    test('反向拖选（anchor > focus）文本顺序仍按文档顺序', () {
      final first = ParagraphInfo(
        lines: [lineOf('abc', 0)],
        totalHeight: 24,
        startIndex: 0,
        endIndex: 3,
      );
      final page = PageInfo(paragraphs: [first], totalHeight: 24);
      expect(
        readerSelectionText(
          page,
          const ReaderTextSelection(anchor: 2, focus: 0),
        ),
        'abc',
      );
    });
  });

  group('词级起选（中英文常见情况）', () {
    final map = ReaderLineSelectionMap(
      _pureLine(text: 'Hello, world! 中文测试 2026年 don\'t well-known 😀a'),
    );

    test('英文整词', () {
      final sel = readerSelectionForWordAt(map, 1);
      expect(sel, isNotNull);
      expect(map.text.substring(sel!.start, sel.endInclusive + 1), 'Hello');
    });

    test('标点按单字符', () {
      final sel = readerSelectionForWordAt(map, 5); // ','
      expect(sel, isNotNull);
      expect(map.text.substring(sel!.start, sel.endInclusive + 1), ',');
    });

    test('英文第二词（跨空格后）', () {
      final sel = readerSelectionForWordAt(map, 8); // 'world'
      expect(sel, isNotNull);
      expect(map.text.substring(sel!.start, sel.endInclusive + 1), 'world');
    });

    test('中文按单字（无 ICU 词典近似）', () {
      final index = map.text.indexOf('中');
      final sel = readerSelectionForWordAt(map, index + 1); // '文'
      expect(sel, isNotNull);
      expect(map.text.substring(sel!.start, sel.endInclusive + 1), '文');
    });

    test('数字整词（含年份后的中文单字）', () {
      final yearIndex = map.text.indexOf('2026');
      final yearSel = readerSelectionForWordAt(map, yearIndex + 2);
      expect(yearSel, isNotNull);
      expect(
        map.text.substring(yearSel!.start, yearSel.endInclusive + 1),
        '2026',
      );
      final nianSel = readerSelectionForWordAt(map, yearIndex + 4);
      expect(nianSel, isNotNull);
      expect(map.text.substring(nianSel!.start, nianSel.endInclusive + 1), '年');
    });

    test('词内连接符并入整词', () {
      final apostrophe = map.text.indexOf("don't");
      final sel1 = readerSelectionForWordAt(map, apostrophe + 2);
      expect(sel1, isNotNull);
      expect(map.text.substring(sel1!.start, sel1.endInclusive + 1), "don't");

      final hyphen = map.text.indexOf('well-known');
      final sel2 = readerSelectionForWordAt(map, hyphen + 6);
      expect(sel2, isNotNull);
      expect(
        map.text.substring(sel2!.start, sel2.endInclusive + 1),
        'well-known',
      );
    });

    test('纯函数词边界：代理对不拆分', () {
      const text = '😀a';
      expect(readerWordRangeAt(text, 0), const ReaderWordRange(0, 2));
      expect(
        readerWordRangeAt(text, 1),
        const ReaderWordRange(0, 2),
        reason: '低代理项下标应对齐到字形簇起点',
      );
      expect(readerWordRangeAt(text, 2), const ReaderWordRange(2, 3));
    });

    test('纯函数词边界：组合附加符号跟随基字符', () {
      const text = 'e\u0301x';
      expect(readerWordRangeAt(text, 0), const ReaderWordRange(0, 3));
      expect(readerWordRangeAt(text, 1), const ReaderWordRange(0, 3));
    });

    test('纯函数词边界：空白/连接符单独命中不吞邻词', () {
      const text = 'a - b';
      expect(readerWordRangeAt(text, 2), const ReaderWordRange(2, 3));
      expect(readerWordRangeAt(text, 0), const ReaderWordRange(0, 1));
      expect(readerWordRangeAt(text, 4), const ReaderWordRange(4, 5));
    });

    test('空行/越界偏移安全返回', () {
      expect(readerWordRangeAt('', 0), const ReaderWordRange(0, 0));
      expect(
        readerWordRangeAt('abc', 99),
        const ReaderWordRange(0, 3),
        reason: '越界偏移钳到最后字符所在词',
      );
    });

    test('缩进行点击落在缩进区时选段首字符', () {
      final indentMap = ReaderLineSelectionMap(
        _pureLine(text: '　　正文', chapterStart: 50, skip: 2),
      );
      final sel = readerSelectionForWordAt(indentMap, 0);
      expect(sel, isNotNull);
      expect(sel!.start, 50);
      expect(sel.endInclusive, 50);
      expect(
        indentMap.localRangeFor(sel.start, sel.endExclusive),
        (2, 3),
        reason: '缩进列不进入选区，落到段首「正」',
      );
    });
  });
}

class _FakeBuildContext extends Fake implements BuildContext {}
