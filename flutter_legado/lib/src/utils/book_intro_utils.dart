// 书籍简介展示文本（设置批6a-1）
//
// 书架列表「更多信息」需要把书源简介里的 HTML 片段转成纯文本。参考版
// 走 `HtmlFormatter.formatIntroText/formatSummaryText`；我方只做展示层
// 最小净化：去标签、还原常见实体、压缩空白，不改变入库数据。
//
// 编写：全栈工程师（设置批6a-1） ｜ 2026-11-06
library;

/// 常见 HTML 实体还原（顺序敏感：&amp; 最后处理，避免二次解码）
const Map<String, String> _entities = {
  '&nbsp;': ' ',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&apos;': "'",
  '&amp;': '&',
};

/// 简介纯文本（空串/仅空白返回空串）
String plainBookIntro(String? html) {
  if (html == null || html.isEmpty) return '';
  var text = html
      .replaceAll(RegExp(r'<(br|/p|/div|/li)\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  for (final entry in _entities.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  // 压缩连续空白（保留段落换行语义，展示层按 maxLines 截断即可）
  return text
      .replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n')
      .trim();
}
