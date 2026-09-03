import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// 帮助 Markdown 分隔线色
/// [UI_MD3_ALIGNMENT_PLAN.md Batch B B9] 走 tonal outlineVariant
Color helpMarkdownDividerColor(ThemeData theme) {
  return theme.colorScheme.outlineVariant;
}

/// 帮助 Markdown 样式（对标 Android HelpMarkwonTheme + secondaryText）
MarkdownStyleSheet helpMarkdownStyleSheet(ThemeData theme) {
  final cs = theme.colorScheme;
  // [UI_MD3_ALIGNMENT_PLAN.md Batch B B9] 正文走 tonal onSurfaceVariant
  final bodyColor = cs.onSurfaceVariant;
  final accent = cs.primary;
  final breakColor = helpMarkdownDividerColor(theme);
  final codeBg = Color.alphaBlend(
    cs.onSurface.withValues(alpha: 0.06),
    cs.surface,
  );
  final inlineCodeBg = Color.alphaBlend(
    cs.onSurface.withValues(alpha: 0.10),
    cs.surface,
  );

  final base = theme.textTheme.bodyLarge?.copyWith(
        color: bodyColor,
        height: 1.3,
        fontSize: 15,
      ) ??
      TextStyle(color: bodyColor, height: 1.3, fontSize: 15);

  TextStyle heading(int level, {Color? color, FontWeight? weight}) {
    final scale = switch (level) {
      1 => 1.45,
      2 => 1.3,
      3 => 1.15,
      4 => 1.05,
      _ => 1.0,
    };
    return base.copyWith(
      fontSize: (base.fontSize ?? 15) * scale,
      fontWeight: weight ?? FontWeight.w600,
      color: color ?? cs.onSurface,
      height: 1.25,
    );
  }

  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: base,
    pPadding: const EdgeInsets.only(bottom: 10),
    h1: heading(1),
    h1Padding: const EdgeInsets.only(top: 4, bottom: 0),
    h2: heading(2, color: cs.onSurfaceVariant),
    h2Padding: const EdgeInsets.only(top: 20, bottom: 0),
    h2Align: WrapAlignment.start,
    h3: heading(3, color: cs.onSurface),
    h3Padding: const EdgeInsets.only(top: 14, bottom: 6),
    h4: heading(4),
    h5: heading(5),
    h6: heading(6, color: cs.onSurfaceVariant),
    strong: base.copyWith(
      color: cs.onSurface,
      fontWeight: FontWeight.w600,
    ),
    em: base.copyWith(fontStyle: FontStyle.italic),
    a: base.copyWith(color: accent, decoration: TextDecoration.none),
    listBullet: base.copyWith(color: accent),
    listIndent: 24,
    blockSpacing: 12,
    blockquote: base.copyWith(color: cs.onSurfaceVariant),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: accent, width: 3),
      ),
    ),
    code: TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['Consolas', 'monospace'],
      fontSize: 13,
      color: cs.onSurface,
      backgroundColor: inlineCodeBg,
    ),
    codeblockPadding: const EdgeInsets.all(10),
    codeblockDecoration: BoxDecoration(
      color: codeBg,
      borderRadius: BorderRadius.circular(6),
    ),
    horizontalRuleDecoration: BoxDecoration(
      color: breakColor,
      borderRadius: BorderRadius.zero,
    ),
    tableHead: heading(4, color: cs.onSurface),
    tableBody: base,
    tableBorder: TableBorder.all(color: breakColor, width: 1),
    tableCellsPadding: const EdgeInsets.all(8),
    tableHeadAlign: TextAlign.left,
  );
}
