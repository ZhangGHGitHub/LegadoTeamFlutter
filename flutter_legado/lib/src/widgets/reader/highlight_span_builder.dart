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
///
/// [matches] 约定按 `(start 升序, order 升序)` 排列（Rust 输出与
/// `parseHighlightMatches` 均保证）；本函数仍做一次 O(n) 有序校验，乱序时
/// 稳定排序兜底——下方按 `start >= bodyEnd` 提前 `break`，乱序输入会漏掉
/// 后续命中区间的 span（批34b P2-2）。
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

  final ordered = _startSorted(matches);
  final bodyStart = chapterStart;
  final bodyEnd = chapterStart + (text.length - skip);
  final spans = <InlineSpan>[];
  if (skip > 0) {
    // 首行缩进列不参与高亮（对齐原版 HighlightMatcher 的缩进列跳过语义）
    spans.add(TextSpan(text: text.substring(0, skip)));
  }

  var cursor = skip;
  for (final match in ordered) {
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

/// 校验命中列表按 `start` 升序；乱序时返回稳定排序后的副本
///
/// 升序输入直接返回原列表（零分配）；乱序才复制排序，保证渲染不丢区间。
List<HighlightMatch> _startSorted(List<HighlightMatch> matches) {
  for (var i = 1; i < matches.length; i++) {
    if (matches[i].start < matches[i - 1].start) {
      return [...matches]..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : a.order.compareTo(b.order);
      });
    }
  }
  return matches;
}

/// 高亮样式 → 稀疏 [TextStyle]（未指定的字段由父级 [TextSpan] 继承）
///
/// 返回 null 表示无可渲染效果（调用方仍可生成普通 span）。
TextStyle? highlightTextStyle(HighlightStyle style) {
  if (!style.hasRenderableEffect) return null;

  final color = style.textColor != 0 ? Color(style.textColor) : null;
  final background = style.fill != 0 ? Color(style.fill) : null;

  // 批34c：线条颜色回退对齐原版 `HighlightDraw.drawRun` 的 fallbackColor 语义
  // （`style.textColor.takeIf { it != 0 } ?: 正文色`）：underline.color /
  // strike.color 为 0 时用规则 textColor；规则也没有 textColor 时保持 null，
  // 由 Flutter 按正文色绘制。设备验收发现未显式回退时下划线会落到正文基色，
  // 与规则 textColor 不一致。— full-stack-engineer + UI
  final lineFallbackColor = style.textColor != 0
      ? Color(style.textColor)
      : null;

  final decorations = <TextDecoration>[];
  final underline = style.underline;
  // [审查 P3] 对齐上游「width=0 = 不画线」：只有 width > 0 才加下划线装饰；
  // 此前 width=0 仍会加装饰并落到 Flutter 默认厚度，与用户设置不符。
  final underlineVisible = underline != null && underline.width > 0;
  if (underlineVisible) decorations.add(TextDecoration.underline);
  if (style.strike) decorations.add(TextDecoration.lineThrough);
  final decoration = decorations.isEmpty
      ? null
      : TextDecoration.combine(decorations);

  TextDecorationStyle? decorationStyle;
  Color? decorationColor;
  double? decorationThickness;
  if (underline != null && underline.width > 0) {
    decorationStyle = _decorationStyle(underline.kind);
    decorationColor = underline.color != 0
        ? Color(underline.color)
        : lineFallbackColor;
    decorationThickness = underline.width;
  }
  if (decorationColor == null && style.strike) {
    // 删除线同款回退：自身颜色 → 规则 textColor → 正文色
    decorationColor = style.strikeColor != 0
        ? Color(style.strikeColor)
        : lineFallbackColor;
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
