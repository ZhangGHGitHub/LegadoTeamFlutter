// 书架展示标签（批35）：对齐参考版 `BookShelfItem.getDisplayTags`
// （`BookShelfItem.kt:53-68`）——只影响书架卡片/列表行的标签渲染，
// 不改变搜索匹配的数据来源。

import '../models/book.dart';

/// 按「用户标签 / 书源分类 / 字数」三项开关计算书架展示标签。
///
/// 语义与参考版逐条对齐：
/// - 自定义标签 `customTag`、书源分类 `kind` 均按 `,` 或换行拆分，
///   逐项 trim 后丢弃空串；
/// - 书源分类与已收集标签去重（同标签只显示一次）；
/// - 字数 `wordCount` 非空且不与已有标签重复时追加；
/// - 空值 / 空白串不产生标签（调用方据此不渲染空行）。
List<String> bookDisplayTags(
  Book book, {
  bool showCustomTags = true,
  bool showSourceTags = true,
  bool showWordCount = true,
}) {
  final tags = <String>[];
  if (showCustomTags) {
    tags.addAll(_splitTagText(book.customTag));
  }
  if (showSourceTags) {
    for (final tag in _splitTagText(book.kind)) {
      if (!tags.contains(tag)) tags.add(tag);
    }
  }
  final wordCount = book.wordCount?.trim() ?? '';
  if (showWordCount && wordCount.isNotEmpty && !tags.contains(wordCount)) {
    tags.add(wordCount);
  }
  return tags;
}

/// 拆分标签文本（对齐原版 `splitNotBlank(",", "\n")`：逗号/换行分隔、
/// 逐项 trim、丢弃空白项）。
Iterable<String> _splitTagText(String? text) sync* {
  if (text == null || text.isEmpty) return;
  for (final part in text.split(RegExp(r'[,\n]'))) {
    final tag = part.trim();
    if (tag.isNotEmpty) yield tag;
  }
}
