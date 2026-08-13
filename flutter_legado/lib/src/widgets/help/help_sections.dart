/// 帮助文档章节（对标 Android HelpSections.kt）
class HelpSection {
  const HelpSection({required this.title, required this.markdown});

  final String title;
  final String markdown;
}

/// 从 Markdown 按 ## 或 ### 标题切分目录（与原版 parseHelpSections 一致）
List<HelpSection> parseHelpSections(String markdown) {
  final lines = markdown.split('\n');
  return _splitHelpSections(lines, 2) ?? _splitHelpSections(lines, 3) ?? const [];
}

List<HelpSection>? _splitHelpSections(List<String> lines, int level) {
  final headings = _findHelpHeadings(lines, level);
  if (headings.length < 2) return null;
  return [
    for (var i = 0; i < headings.length; i++)
      HelpSection(
        title: headings[i].title,
        markdown: lines
            .sublist(
              headings[i].index,
              headings.elementAtOrNull(i + 1)?.index ?? lines.length,
            )
            .join('\n')
            .trimRight(),
      ),
  ];
}

class _HeadingIndex {
  const _HeadingIndex(this.index, this.title);
  final int index;
  final String title;
}

List<_HeadingIndex> _findHelpHeadings(List<String> lines, int level) {
  final headings = <_HeadingIndex>[];
  _FenceMarker? openFence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final marker = _fenceMarker(line);
    if (openFence == null && marker != null) {
      openFence = marker;
      continue;
    }
    if (openFence?.isClosedBy(marker) == true) {
      openFence = null;
      continue;
    }
    if (openFence == null) {
      final title = _headingTitle(line, level);
      if (title != null) headings.add(_HeadingIndex(i, title));
    }
  }
  return headings;
}

class _FenceMarker {
  const _FenceMarker(this.character, this.length, this.trailing);

  final String character;
  final int length;
  final String trailing;

  bool isClosedBy(_FenceMarker? marker) {
    return marker != null &&
        marker.character == character &&
        marker.length >= length &&
        marker.trailing.trim().isEmpty;
  }
}

_FenceMarker? _fenceMarker(String line) {
  final trimmed = line.trimLeft();
  if (line.length - trimmed.length > 3) return null;
  if (trimmed.isEmpty) return null;
  final first = trimmed[0];
  if (first != '`' && first != '~') return null;
  final run = RegExp('^${RegExp.escape(first)}+').firstMatch(trimmed);
  if (run == null) return null;
  final length = run.group(0)!.length;
  if (length < 3) return null;
  return _FenceMarker(first, length, trimmed.substring(length));
}

String? _headingTitle(String line, int level) {
  final trimmed = line.trimLeft();
  if (line.length - trimmed.length > 3) return null;
  final prefix = '${'#' * level} ';
  if (!trimmed.startsWith(prefix)) return null;
  final title = trimmed.substring(prefix.length).trim();
  return title.isEmpty ? null : title;
}

extension<T> on List<T> {
  T? elementAtOrNull(int index) =>
      index >= 0 && index < length ? this[index] : null;
}
