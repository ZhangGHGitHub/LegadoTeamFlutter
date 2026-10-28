/// 阅读页正文高亮渲染接线测试（批34）
///
/// 验证 ReaderTextContent 在命中区间存在时改走 Text.rich，并按行内
/// `chapterStartIndex`/`highlightSkip` 把样式落到正确的字符上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/highlight_style.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';

void main() {
  ParagraphInfo paragraph({
    required List<String> words,
    int chapterStart = 0,
    int highlightSkip = 0,
    int startIndex = 0,
  }) {
    final length = words.join().length;
    return ParagraphInfo(
      lines: [
        LineInfo(
          words: words,
          width: 120,
          height: 24,
          startIndex: highlightSkip,
          endIndex: length,
          chapterStartIndex: chapterStart,
          highlightSkip: highlightSkip,
          highlightMapped: true,
        ),
      ],
      totalHeight: 24,
      startIndex: startIndex,
      endIndex: startIndex + length - highlightSkip,
      chapterParagraphIndex: 1,
    );
  }

  Future<void> pumpContent(
    WidgetTester tester, {
    required PageInfo pageInfo,
    required List<HighlightMatch> matches,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderTextContent(
            pageInfo: pageInfo,
            fontSize: 16,
            lineHeight: 1.5,
            paragraphSpacing: 0,
            textColor: Colors.black,
            highlightMatches: matches,
          ),
        ),
      ),
    );
  }

  /// 在渲染树的 RichText 中递归查找指定文本且带样式的 span
  bool hasStyledSpan(
    WidgetTester tester,
    String text, {
    Color? background,
    Color? color,
    TextDecoration? decoration,
  }) {
    bool walk(InlineSpan span) {
      if (span is! TextSpan) return false;
      if (span.text == text) {
        final style = span.style;
        if (style != null) {
          final backgroundOk =
              background == null || style.backgroundColor == background;
          final colorOk = color == null || style.color == color;
          final decorationOk =
              decoration == null || style.decoration == decoration;
          if (backgroundOk && colorOk && decorationOk) return true;
        }
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (walk(child)) return true;
      }
      return false;
    }

    for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
      if (walk(richText.text)) return true;
    }
    return false;
  }

  /// 递归查找指定文本的 span（可断言其 style）
  List<TextSpan> findSpans(WidgetTester tester, String text) {
    final result = <TextSpan>[];
    void walk(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.text == text) result.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
      walk(richText.text);
    }
    return result;
  }

  testWidgets('命中区间渲染为带背景色的 span', (tester) async {
    final pageInfo = PageInfo(
      paragraphs: [paragraph(words: ['第一段正文'])],
      totalHeight: 24,
    );
    await pumpContent(
      tester,
      pageInfo: pageInfo,
      matches: [
        HighlightMatch(
          ruleId: 1,
          start: 0,
          end: 2,
          order: 0,
          style: HighlightStyle.fromMap(const {'fill': 0x80FFF176}),
        ),
      ],
    );
    expect(
      hasStyledSpan(tester, '第一', background: const Color(0x80FFF176)),
      isTrue,
    );
  });

  testWidgets('缩进列不套高亮，正文高亮从缩进后开始', (tester) async {
    final pageInfo = PageInfo(
      paragraphs: [paragraph(words: ['　　正文'], highlightSkip: 2)],
      totalHeight: 24,
    );
    await pumpContent(
      tester,
      pageInfo: pageInfo,
      matches: [
        HighlightMatch(
          ruleId: 2,
          start: 0,
          end: 2,
          order: 1,
          style: HighlightStyle.fromMap(const {'textColor': 0xFFFF0000}),
        ),
      ],
    );
    // 命中落在正文前两字（行内下标 2..4），缩进全角空格保持普通样式
    expect(
      hasStyledSpan(tester, '正文', color: const Color(0xFFFF0000)),
      isTrue,
    );
    final indentSpans = findSpans(tester, '　　');
    expect(indentSpans, isNotEmpty);
    for (final span in indentSpans) {
      expect(span.style?.color, isNull);
      expect(span.style?.backgroundColor, isNull);
    }
  });

  testWidgets('跨行命中按行全局偏移裁剪（第二行只染后半段）', (tester) async {
    // 第一行 0..4，第二行全局 4..8；命中 2..6 → 第二行 4..6（行内 0..2）
    const first = ParagraphInfo(
      lines: [
        LineInfo(
          words: ['一二三四'],
          width: 120,
          height: 24,
          startIndex: 0,
          endIndex: 4,
          chapterStartIndex: 0,
          highlightMapped: true,
        ),
        LineInfo(
          words: ['五六七八'],
          width: 120,
          height: 24,
          startIndex: 4,
          endIndex: 8,
          chapterStartIndex: 4,
          highlightMapped: true,
        ),
      ],
      totalHeight: 48,
      startIndex: 0,
      endIndex: 8,
      chapterParagraphIndex: 1,
    );
    await pumpContent(
      tester,
      pageInfo: const PageInfo(paragraphs: [first], totalHeight: 48),
      matches: [
        HighlightMatch(
          ruleId: 3,
          start: 2,
          end: 6,
          order: 2,
          style: HighlightStyle.fromMap(const {'strike': {'color': 0xFF9E9E9E}}),
        ),
      ],
    );
    expect(
      hasStyledSpan(tester, '五六', decoration: TextDecoration.lineThrough),
      isTrue,
    );
  });
}
