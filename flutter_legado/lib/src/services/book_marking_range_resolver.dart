/// 书签标记锚点 → 章节正文区间解析（批7b-2b）
///
/// 对齐参考版 `BookContentProcessEngine.findTargetRange`（`BookContentProcessEngine.kt:101-170`）：
/// 1. 候选文本 = `[selectedText, normalizeMarkingText(selectedText)]`，trim 去空去重；
/// 2. 精确匹配：`content.indexOf` 全部出现位置，取离 `chapterPosition ?? 0`
///    最近的一次（`findClosestOccurrence`）；
/// 3. 归一化回退：连续空白（`\n`/`\r`/`\t`/全角空格等）折叠为单空格，
///    建立「归一化下标 → 原文下标」映射，匹配后映射回原文区间；
///    映射越界/无法定位边界 → null（保守失败）。
///
/// 本文件为纯函数，不依赖 Flutter；任何异常输入返回 null，不抛错。
library;

import '../models/book_marking_style.dart';

/// 章节正文中的 UTF-16 半开区间
typedef BookMarkingRange = ({int start, int end});

/// 解析锚点对应的章节正文区间；无法定位返回 null
BookMarkingRange? resolveBookMarkingRange(
  String content,
  BookMarkingAnchor anchor,
) {
  if (content.isEmpty) return null;
  final candidates = <String>[
    anchor.selectedText.trim(),
    normalizeMarkingText(anchor.selectedText).trim(),
  ].where((c) => c.isNotEmpty).toSet().toList();
  if (candidates.isEmpty) return null;

  final approximate = anchor.chapterPosition ?? 0;
  // 1) 精确匹配：候选原文逐字出现在 content 中
  for (final candidate in candidates) {
    final start = _findClosestOccurrence(content, candidate, approximate);
    if (start >= 0) {
      final end = start + candidate.length;
      if (end <= content.length) {
        return (start: start, end: end);
      }
    }
  }

  // 2) 归一化回退：连续空白折叠为单空格后匹配，再映射回原文下标
  final normalizedContent = _normalizeWithMapping(content);
  if (normalizedContent.text.isEmpty) return null;
  for (final candidate in candidates) {
    final normalizedCandidate = _normalizeWithMapping(candidate).text;
    if (normalizedCandidate.isEmpty) continue;
    final range = _findClosestNormalizedOccurrence(
      normalizedContent: normalizedContent,
      normalizedCandidate: normalizedCandidate,
      approximatePosition: approximate,
    );
    if (range != null && range.end <= content.length && range.start >= 0) {
      return range;
    }
  }
  return null;
}

/// 精确匹配：返回离 [approximatePosition] 最近的一次起始下标（并列取先出现者）
int _findClosestOccurrence(
  String content,
  String selectedText,
  int approximatePosition,
) {
  var match = content.indexOf(selectedText);
  if (match < 0) return -1;
  var closest = match;
  var closestDistance = (match - approximatePosition).abs();
  while (true) {
    match = content.indexOf(selectedText, match + 1);
    if (match < 0) break;
    final distance = (match - approximatePosition).abs();
    if (distance < closestDistance) {
      closest = match;
      closestDistance = distance;
    }
  }
  return closest;
}

/// 归一化文本 + 原文下标映射
class _NormalizedText {
  const _NormalizedText(this.text, this.sourceStart, this.sourceEnd);

  /// 折叠空白后的文本
  final String text;

  /// 每个归一化字符对应的原文起始下标（含）
  final List<int> sourceStart;

  /// 每个归一化字符对应的原文结束下标（不含；空白段为整段末尾）
  final List<int> sourceEnd;
}

bool _isProcessWhitespace(int code) => code <= 0x20 || code == 0x3000;

/// 连续空白折叠为单空格，并记录每个归一化字符的原文区间
_NormalizedText _normalizeWithMapping(String source) {
  final buffer = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];
  var i = 0;
  while (i < source.length) {
    final code = source.codeUnitAt(i);
    if (_isProcessWhitespace(code)) {
      final start = i;
      while (i < source.length && _isProcessWhitespace(source.codeUnitAt(i))) {
        i++;
      }
      buffer.write(' ');
      starts.add(start);
      ends.add(i);
      continue;
    }
    buffer.writeCharCode(code);
    starts.add(i);
    ends.add(i + 1);
    i++;
  }
  return _NormalizedText(buffer.toString(), starts, ends);
}

/// 归一化匹配：返回映射回原文的最近区间
BookMarkingRange? _findClosestNormalizedOccurrence({
  required _NormalizedText normalizedContent,
  required String normalizedCandidate,
  required int approximatePosition,
}) {
  var match = normalizedContent.text.indexOf(normalizedCandidate);
  if (match < 0) return null;
  var closestStart = match;
  var closestDistance = _distance(
    normalizedContent,
    match,
    approximatePosition,
  );
  while (true) {
    match = normalizedContent.text.indexOf(normalizedCandidate, match + 1);
    if (match < 0) break;
    final distance = _distance(normalizedContent, match, approximatePosition);
    if (distance < closestDistance) {
      closestStart = match;
      closestDistance = distance;
    }
  }
  final lastIndex = closestStart + normalizedCandidate.length - 1;
  if (closestStart < 0 ||
      lastIndex < 0 ||
      closestStart >= normalizedContent.sourceStart.length ||
      lastIndex >= normalizedContent.sourceEnd.length) {
    return null;
  }
  final start = normalizedContent.sourceStart[closestStart];
  final end = normalizedContent.sourceEnd[lastIndex];
  if (start < 0 || end <= start) return null;
  return (start: start, end: end);
}

int _distance(
  _NormalizedText normalizedContent,
  int normalizedIndex,
  int approximatePosition,
) {
  if (normalizedIndex < 0 ||
      normalizedIndex >= normalizedContent.sourceStart.length) {
    return 1 << 30;
  }
  return (normalizedContent.sourceStart[normalizedIndex] - approximatePosition)
      .abs();
}
