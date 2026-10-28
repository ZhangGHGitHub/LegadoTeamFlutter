/// 高亮渲染切分 / 章节偏移映射 / 匹配缓存测试（批34）
///
/// 覆盖：
/// - 命中区间 → InlineSpan 切分（含非 BMP、缩进列跳过、跨行裁剪、多规则）
/// - HighlightStyle → TextStyle（颜色/背景/下划线/删除线，不含字体度量）
/// - paragraph_layout_engine 段落/行章节全局偏移（缩进段 + 多行）
/// - HighlightMatchCache 按章节 key + 规则修订号失效与 LRU
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/highlight_style.dart';
import 'package:flutter_legado/src/services/highlight_match_cache.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/highlight_span_builder.dart';

void main() {
  group('buildHighlightedLineSpans - 命中区间切分', () {
    HighlightMatch match(
      int start,
      int end, {
      int order = 0,
      Map<String, dynamic> style = const {'textColor': -16777216},
    }) {
      return HighlightMatch(
        ruleId: order + 1,
        start: start,
        end: end,
        order: order,
        style: HighlightStyle.fromMap(style),
      );
    }

    test('非 BMP 字符按 UTF-16 下标切分', () {
      // 😀 占 2 个 code unit；命中 2..5 = 「关键词」
      final spans = buildHighlightedLineSpans(
        text: '😀关键词',
        chapterStart: 0,
        highlightSkip: 0,
        matches: [match(2, 5)],
      );
      expect(spans.length, 2);
      expect((spans[0] as TextSpan).text, '😀');
      expect((spans[0] as TextSpan).style, isNull);
      final styled = spans[1] as TextSpan;
      expect(styled.text, '关键词');
      expect(styled.style?.color, const Color(0xFF000000));
    });

    test('首行缩进列不参与高亮', () {
      // 行文本 = 2 个全角缩进 + 正文；命中 0..2（正文前两字）
      final spans = buildHighlightedLineSpans(
        text: '　　第一段',
        chapterStart: 0,
        highlightSkip: 2,
        matches: [match(0, 2)],
      );
      expect(spans.length, 3);
      expect((spans[0] as TextSpan).text, '　　');
      expect((spans[0] as TextSpan).style, isNull);
      expect((spans[1] as TextSpan).text, '第一');
      expect((spans[1] as TextSpan).style?.color, const Color(0xFF000000));
      expect((spans[2] as TextSpan).text, '段');
    });

    test('多规则多区间：样式各自独立，区间外保持普通文本', () {
      final spans = buildHighlightedLineSpans(
        text: '一二三四五',
        chapterStart: 0,
        highlightSkip: 0,
        matches: [
          match(0, 1, order: 1, style: {'fill': -2130710154}),
          match(2, 4, order: 5, style: {'textColor': -65536}),
        ],
      );
      expect(
        spans.map((s) => (s as TextSpan).text).toList(),
        ['一', '二', '三四', '五'],
      );
      expect((spans[0] as TextSpan).style?.backgroundColor, const Color(0x80FFF176));
      expect((spans[2] as TextSpan).style?.color, const Color(0xFFFF0000));
      expect((spans[1] as TextSpan).style, isNull);
      expect((spans[3] as TextSpan).style, isNull);
    });

    test('跨行命中按本行可见区间裁剪', () {
      // 行对应章节 10..16，命中 8..12 → 本行只高亮 10..12（行内 0..2）
      final spans = buildHighlightedLineSpans(
        text: 'ABCDEF',
        chapterStart: 10,
        highlightSkip: 0,
        matches: [match(8, 12)],
      );
      expect(spans.length, 2);
      expect((spans[0] as TextSpan).text, 'AB');
      expect((spans[0] as TextSpan).style, isNotNull);
      expect((spans[1] as TextSpan).text, 'CDEF');
      expect((spans[1] as TextSpan).style, isNull);
    });

    test('乱序输入不丢 span（函数内有序兜底）', () {
      // 批34b P2-2：matches 约定按 start 升序；乱序时按 (start, order)
      // 稳定排序后再切分，避免 `start >= bodyEnd` 提前 break 漏掉区间
      final spans = buildHighlightedLineSpans(
        text: '一二三四五六',
        chapterStart: 0,
        highlightSkip: 0,
        matches: [
          match(4, 6),
          match(0, 1),
          match(2, 3),
        ],
      );
      expect(
        spans.map((s) => (s as TextSpan).text).toList(),
        ['一', '二', '三', '四', '五六'],
      );
      expect((spans[0] as TextSpan).style, isNotNull);
      expect((spans[1] as TextSpan).style, isNull);
      expect((spans[2] as TextSpan).style, isNotNull);
      expect((spans[3] as TextSpan).style, isNull);
      expect((spans[4] as TextSpan).style, isNotNull);
    });

    test('无命中/空文本返回单 span', () {
      final plain = buildHighlightedLineSpans(
        text: '正文',
        chapterStart: 0,
        highlightSkip: 0,
        matches: const [],
      );
      expect(plain.length, 1);
      expect((plain.first as TextSpan).text, '正文');
      expect((plain.first as TextSpan).style, isNull);

      final empty = buildHighlightedLineSpans(
        text: '',
        chapterStart: 0,
        highlightSkip: 0,
        matches: [match(0, 1)],
      );
      expect(empty.length, 1);
      expect((empty.first as TextSpan).text, '');
    });
  });

  group('highlightTextStyle - 样式映射', () {
    test('下划线 + 删除线合并，颜色/线型/粗细生效', () {
      final style = HighlightStyle.parse(
        '{"textColor":-16777216,"fill":-2130710154,'
        '"underline":{"kind":"wavy","color":-1754827,"width":2},'
        '"strike":{"color":-6381922}}',
      );
      final textStyle = highlightTextStyle(style);
      expect(textStyle, isNotNull);
      expect(textStyle!.color, const Color(0xFF000000));
      expect(textStyle.backgroundColor, const Color(0x80FFF176));
      expect(
        textStyle.decoration,
        TextDecoration.combine([
          TextDecoration.underline,
          TextDecoration.lineThrough,
        ]),
      );
      expect(textStyle.decorationStyle, TextDecorationStyle.wavy);
      expect(textStyle.decorationColor, const Color(0xFFE53935));
      expect(textStyle.decorationThickness, 2);
    });

    test('仅 bold/italic 返回 null（不改变字体度量）', () {
      expect(highlightTextStyle(HighlightStyle.parse('{"bold":true}')), isNull);
      expect(highlightTextStyle(HighlightStyle.parse('{"italic":true}')), isNull);
      expect(highlightTextStyle(HighlightStyle.empty), isNull);
    });
  });

  group('paragraph_layout_engine - 章节全局偏移映射', () {
    late ParagraphLayoutEngine engine;

    setUp(() {
      engine = ParagraphLayoutEngine(
        config: const ParagraphConfig(
          fontSize: 16.0,
          lineHeight: 1.5,
          paragraphSpacing: 8.0,
          indent: 32.0,
          indentCount: 2,
          backgroundColor: Colors.white,
          textColor: Colors.black,
        ),
        context: _FakeBuildContext(),
      );
    });

    test('段落 startIndex/endIndex 为章节全局偏移（含前导空白 trim）', () {
      const content = '  第一段文字。\n\n第二段文字。';
      final pages = engine.paginateChapter(content, 300.0, 600.0);
      final paras = pages.expand((p) => p.paragraphs).toList();
      expect(paras.length, 2);
      expect(paras[0].startIndex, 2);
      expect(paras[0].endIndex, 2 + '第一段文字。'.length);
      expect(paras[1].startIndex, 10);
      expect(paras[1].endIndex, 10 + '第二段文字。'.length);
    });

    test('缩进行 highlightSkip/chapterStartIndex 可还原正文', () {
      const content = '第一段正文内容。';
      final pages = engine.paginateChapter(content, 300.0, 600.0);
      final para = pages.first.paragraphs.first;
      final line = para.lines.first;
      expect(line.highlightMapped, isTrue);
      expect(line.highlightSkip, 2);
      expect(line.chapterStartIndex, para.startIndex);
      final text = line.words.join('');
      final body = text.substring(line.highlightSkip);
      expect(
        body,
        content.substring(
          para.startIndex,
          para.startIndex + body.length,
        ),
      );
    });

    test('多行段落每行全局偏移连续且可还原正文', () {
      final content = List.filled(80, '多行映射测试').join();
      final pages = engine.paginateChapter(content, 120.0, 600.0);
      final para = pages.first.paragraphs.first;
      expect(para.lines.length, greaterThan(1));
      for (final line in para.lines) {
        final text = line.words.join('');
        final bodyLength = text.length - line.highlightSkip;
        expect(bodyLength, greaterThan(0));
        final expected = content.substring(
          line.chapterStartIndex,
          line.chapterStartIndex + bodyLength,
        );
        expect(text.substring(line.highlightSkip), expected);
      }
      // 相邻行正文首尾相接（无重叠/漏字）
      for (var i = 0; i + 1 < para.lines.length; i++) {
        final current = para.lines[i];
        final next = para.lines[i + 1];
        final currentBodyLength =
            current.words.join('').length - current.highlightSkip;
        expect(
          next.chapterStartIndex,
          current.chapterStartIndex + currentBodyLength,
        );
      }
    });
  });

  group('HighlightMatchCache - 章节缓存与失效', () {
    HighlightMatch build(int start) => HighlightMatch(
      ruleId: 1,
      start: start,
      end: start + 1,
      order: 0,
      style: HighlightStyle.empty,
    );

    test('命中按 key + 规则修订号判定', () {
      final cache = HighlightMatchCache();
      cache.store('ch1', 0, [build(0)]);
      expect(cache.lookup('ch1', 0), isNotNull);
      // 规则修订号变化 → 旧缓存失效
      expect(cache.lookup('ch1', 1), isNull);
      expect(cache.lookup('ch2', 0), isNull);
    });

    test('LRU 淘汰最久未用条目', () {
      final cache = HighlightMatchCache(maxEntries: 2);
      cache.store('a', 0, [build(0)]);
      cache.store('b', 0, [build(1)]);
      expect(cache.lookup('a', 0), isNotNull); // 触碰 a
      cache.store('c', 0, [build(2)]); // 淘汰 b
      expect(cache.lookup('b', 0), isNull);
      expect(cache.lookup('a', 0), isNotNull);
      expect(cache.lookup('c', 0), isNotNull);
      expect(cache.length, 2);
    });
  });
}

/// 测试用 FakeBuildContext（TextPainter 不需要真实 context）
class _FakeBuildContext extends Fake implements BuildContext {}
