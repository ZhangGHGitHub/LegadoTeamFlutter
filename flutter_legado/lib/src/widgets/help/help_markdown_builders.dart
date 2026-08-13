import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import 'help_markdown_styles.dart';

/// h1/h2 标题下分隔线（对标 Markwon `headingBreakColor`，仅 H1/H2）
class HelpHeadingBreakBuilder extends MarkdownElementBuilder {
  HelpHeadingBreakBuilder({
    required this.padding,
    required this.dividerColor,
    this.gapBeforeDivider = 6,
    this.gapAfterDivider = 8,
  });

  final EdgeInsets padding;
  final Color dividerColor;
  final double gapBeforeDivider;
  final double gapAfterDivider;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = _plainText(element);
    if (text.isEmpty) return null;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: preferredStyle),
          SizedBox(height: gapBeforeDivider),
          Divider(height: 1, thickness: 1, color: dividerColor),
          SizedBox(height: gapAfterDivider),
        ],
      ),
    );
  }

  String _plainText(md.Element element) {
    final buffer = StringBuffer();
    for (final node in element.children ?? const <md.Node>[]) {
      if (node is md.Text) {
        buffer.write(node.text);
      } else if (node is md.Element) {
        buffer.write(_plainText(node));
      }
    }
    return buffer.toString();
  }
}

/// 帮助 Markdown 自定义块级渲染（H1/H2 heading break）
Map<String, MarkdownElementBuilder> helpMarkdownBuilders(ThemeData theme) {
  final dividerColor = helpMarkdownDividerColor(theme);
  final sheet = helpMarkdownStyleSheet(theme);
  return {
    'h1': HelpHeadingBreakBuilder(
      padding: sheet.h1Padding ?? EdgeInsets.zero,
      dividerColor: dividerColor,
    ),
    'h2': HelpHeadingBreakBuilder(
      padding: sheet.h2Padding ?? EdgeInsets.zero,
      dividerColor: dividerColor,
    ),
  };
}
