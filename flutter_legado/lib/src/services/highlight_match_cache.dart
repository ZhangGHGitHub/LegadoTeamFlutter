/// 正文高亮匹配结果缓存（批34）
///
/// 阅读页滚动/翻页/重排版会多次重建，匹配结果按
/// `(bookUrl, chapterIndex, 文本 hash, 规则修订号)` 缓存，避免重复跨 FFI。
/// 规则修订号由 `highlightRulesRevisionProvider` 提供（规则列表加载/保存/
/// 删除后自增），修订号变化后同 key 也不再命中，必须重新匹配。
library;

import 'dart:collection';

import '../models/highlight_style.dart';

/// 命中缓存条目
class _Entry {
  const _Entry(this.rulesRevision, this.matches);

  final int rulesRevision;
  final List<HighlightMatch> matches;
}

/// 小容量 LRU 命中缓存（默认 4 章，覆盖当前章 + 相邻章预载余量）
class HighlightMatchCache {
  HighlightMatchCache({this.maxEntries = 4}) : assert(maxEntries > 0);

  final int maxEntries;
  final LinkedHashMap<String, _Entry> _entries = LinkedHashMap<String, _Entry>();

  /// 当前缓存条目数
  int get length => _entries.length;

  /// 查询缓存；命中时刷新 LRU 顺序，修订号不一致则丢弃该条目
  List<HighlightMatch>? lookup(String key, int rulesRevision) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (entry.rulesRevision != rulesRevision) return null;
    _entries[key] = entry;
    return entry.matches;
  }

  /// 写入缓存并淘汰最久未用条目
  void store(String key, int rulesRevision, List<HighlightMatch> matches) {
    _entries.remove(key);
    _entries[key] = _Entry(rulesRevision, List.unmodifiable(matches));
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 清空缓存（章节切换/退出阅读页时可调用）
  void clear() => _entries.clear();
}
