/// 阅读页正文高亮 span 构建（批34 MVP）
///
/// 只应用**不改变字体度量**的样式：前景色 / 背景色（统一矩形）/
/// 下划线 / 删除线。`bold`/`italic` 会改变字体宽度，本批明确不渲染，
/// 避免命中行与分页测量结果不一致导致行尾裁字。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/highlight_style.dart';

/// 把一行文本按章节全局命中区间切分为 [InlineSpan] 列表
///
/// - [text]：该行渲染文本（`line.words.join('')`）；
/// - [chapterStart]：`text[highlightSkip]` 对应的章节全局 UTF-16 偏移；
/// - [highlightSkip]：行首不可高亮字符数（首行缩进全角空格）；
/// - [matches]：Rust `highlightRuleMatch` 结果（UTF-16 半开区间，互不重叠）。
List<InlineSpan> buildHighlightedLineSpans({
  required String text,
  required int chapterStart,
  required int highlightSkip,
  required List<HighlightMatch> matches,
}) {
  if (text.isEmpty) return const [TextSpan(text: '')];
  final skip = highlightSkip.clamp(0, text.length);
  if (matches.isEmpty || skip >= text.length) {
    return [TextSpan(text: text)];
  }

  final bodyStart = chapterStart;
  final bodyEnd = chapterStart + (text.length - skip);
  final spans = <InlineSpan>[];
  if (skip > 0) {
    // 首行缩进列不参与高亮（对齐原版 HighlightMatcher 的缩进列跳过语义）
    spans.add(TextSpan(text: text.substring(0, skip)));
  }

  var cursor = skip;
  for (final match in matches) {
    if (match.end <= bodyStart) continue;
    if (match.start >= bodyEnd) break;
    final start = (math.max(match.start, bodyStart) - bodyStart + skip).clamp(
      0,
      text.length,
    );
    final end = (math.min(match.end, bodyEnd) - bodyStart + skip).clamp(
      0,
      text.length,
    );
    if (end <= cursor) continue;
    if (start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, start)));
      cursor = start;
    }
    final styleEnd = math.max(cursor, end);
    spans.add(
      TextSpan(
        text: text.substring(cursor, styleEnd),
        style: highlightTextStyle(match.style),
      ),
    );
    cursor = styleEnd;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans;
}

/// 高亮样式 → 稀疏 [TextStyle]（未指定的字段由父级 [TextSpan] 继承）
///
/// 返回 null 表示无可渲染效果（调用方仍可生成普通 span）。
TextStyle? highlightTextStyle(HighlightStyle style) {
  if (!style.hasRenderableEffect) return null;

  final color = style.textColor != 0 ? Color(style.textColor) : null;
  final background = style.fill != 0 ? Color(style.fill) : null;

  final decorations = <TextDecoration>[];
  if (style.underline != null) decorations.add(TextDecoration.underline);
  if (style.strike) decorations.add(TextDecoration.lineThrough);
  final decoration = decorations.isEmpty
      ? null
      : TextDecoration.combine(decorations);

  TextDecorationStyle? decorationStyle;
  Color? decorationColor;
  double? decorationThickness;
  final underline = style.underline;
  if (underline != null) {
    decorationStyle = _decorationStyle(underline.kind);
    if (underline.color != 0) {
      decorationColor = Color(underline.color);
    }
    if (underline.width > 0) {
      decorationThickness = underline.width;
    }
  }
  if (decorationColor == null && style.strike && style.strikeColor != 0) {
    decorationColor = Color(style.strikeColor);
  }

  return TextStyle(
    color: color,
    backgroundColor: background,
    decoration: decoration,
    decorationColor: decorationColor,
    decorationStyle: decorationStyle,
    decorationThickness: decorationThickness,
  );
}

/// 原版下划线线型 → Flutter [TextDecorationStyle]
TextDecorationStyle _decorationStyle(String kind) {
  return switch (kind.toUpperCase()) {
    'WAVY' => TextDecorationStyle.wavy,
    'DASHED' => TextDecorationStyle.dashed,
    'DOTTED' => TextDecorationStyle.dotted,
    'DOUBLE' => TextDecorationStyle.double,
    _ => TextDecorationStyle.solid,
  };
}
