import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'search_state.freezed.dart';

/// 搜索页不可变状态
///
/// 对标原 SearchProvider 字段，迁移至 Riverpod 后由 [SearchNotifier] 维护。
/// 展示层派生属性（hasResults/isEmpty/hasFilter）以 extension 表达。
@freezed
class SearchState with _$SearchState {
  const factory SearchState({
    /// 当前搜索关键词
    @Default('') String keyword,

    /// 搜索结果列表（已按书名+作者聚合，对齐原版 mergeItems）
    @Default([]) List<SearchResult> results,

    /// 是否正在搜索
    @Default(false) bool isLoading,

    /// 渐进搜索：已完成书源数（对齐原版 onSearchProgress searched）
    @Default(0) int searchedCount,

    /// 渐进搜索：书源总数（对齐原版 onSearchProgress total）
    @Default(0) int totalCount,

    /// 错误信息
    String? error,

    /// 精准搜索：选中的书源 URL
    @Default(<String>{}) Set<String> selectedSourceUrls,

    /// 精准搜索：选中的分组
    @Default(<String>{}) Set<String> selectedGroups,

    /// 搜索历史（最近 20 条，经 BookApi 持久化至 Rust search_keywords 表）
    /// [审计修复 §4.5] 清理陈旧注释（实际已不走 SharedPreferences） — Qoder
    @Default([]) List<String> searchHistory,

    /// 输入框实时文本（用于联想过滤，区别于已提交的 [keyword]）
    @Default('') String inputText,

    /// 活动搜索会话的当前页码（批次B G-B-01：新关键词 → 重置为 1；
    /// 同关键词续页 → searchPage++，对齐原版 SearchModel.searchPage）
    @Default(1) int searchPage,

    /// 是否有下一页（批次B G-B-02：当前页非空批次的 OR，Rust 侧 has_more
    /// 累积字段；新搜索开始时乐观置 true，每批事件覆写）
    @Default(false) bool hasMore,

    /// 软挂起态（批次B G-B-04：仅门控未派发书源，已派发任务继续；
    /// 对齐原版 repeatOnLifecycle(RESUMED) → viewModel.pause/resume）
    @Default(false) bool isPaused,

    /// 用户手动停止了本次搜索（对齐原版 SearchActivity.isManualStopSearch）：
    /// 抑制 play FAB 与滚动自动加载，直至新关键词搜索重置
    @Default(false) bool isManualStop,
  }) = _SearchState;
}

/// 展示层派生属性
extension SearchStateDisplay on SearchState {
  /// 是否有搜索结果
  bool get hasResults => results.isNotEmpty;

  /// 空结果态（已搜索、非加载、有关键词但无结果）
  bool get isEmpty => results.isEmpty && !isLoading && keyword.isNotEmpty;

  /// 是否存在筛选条件（分组或书源）
  bool get hasFilter => selectedSourceUrls.isNotEmpty || selectedGroups.isNotEmpty;

  /// 联想/历史建议列表
  ///
  /// 对标 Android 原版 SearchActivity.upHistory 的前缀联想行为：
  /// - 输入为空 → 返回全部历史（flowByTime）
  /// - 输入非空 → 返回以输入为前缀的历史关键词（flowSearch 前缀匹配）
  ///
  /// 说明：原版前缀匹配由 DB 查询完成；当前 Rust FFI 未暴露前缀搜索，
  /// 故在客户端对已有历史做前缀过滤（行为等价，待 Rust 轨暴露 FFI 后切换）。
  List<String> get suggestions {
    final input = inputText.trim();
    if (input.isEmpty) return searchHistory;
    return searchHistory.where((w) => w.startsWith(input)).toList();
  }
}

/// 同书聚合 + 分桶排序（严格对齐原版 `SearchModel.mergeItems`）
///
/// 原版行为：
/// 1. 同名同作者合并为一条，`addOrigin` 累加来源（红数字 = origins.size）；
/// 2. 分桶 equal(name==key|author==key) → tags(kind 包含) →
///    contains(name|author 包含) → other；precision 时丢弃 other；
/// 3. 各桶内按 `origins.size` 降序。
///
/// 聚合键使用 [formatBookName]/[formatBookAuthor]（对齐原版 BookList 解析后
/// 再 merge；否则「作者：天蚕土豆」与「天蚕土豆」会拆成多条，徽标偏少）。
///
/// [UI-fix v2.0.31 | 2026-08-11] 此前仅分桶、按 origin 分行，用户体感
/// 「源少/噪声大」；现对齐原版同书多源聚合 — Auto
List<SearchResult> applyPrecisionSearch(
  List<SearchResult> results,
  String key, {
  bool keepOther = true,
}) {
  if (key.isEmpty) return results;

  final equal = <String, SearchResult>{};
  final tags = <String, SearchResult>{};
  final contains = <String, SearchResult>{};
  final other = <String, SearchResult>{};

  void mergeInto(Map<String, SearchResult> bucket, SearchResult item) {
    final name = formatBookName(item.book.name);
    final author = formatBookAuthor(item.book.author);
    final mapKey = '$name\u0000$author';
    final normalized = (name != item.book.name || author != item.book.author)
        ? item.copyWith(book: item.book.copyWith(name: name, author: author))
        : item;
    final existing = bucket[mapKey];
    if (existing == null) {
      bucket[mapKey] = normalized.copyWith(origins: {...normalized.effectiveOrigins});
    } else {
      bucket[mapKey] = existing.withAddedOrigin(normalized);
    }
  }

  for (final r in results) {
    final name = formatBookName(r.book.name);
    final author = formatBookAuthor(r.book.author);
    final kind = r.book.kind ?? '';
    if (name == key || author == key) {
      mergeInto(equal, r);
    } else if (kind.contains(key)) {
      mergeInto(tags, r);
    } else if (name.contains(key) || author.contains(key)) {
      mergeInto(contains, r);
    } else if (keepOther) {
      mergeInto(other, r);
    }
  }

  // 稳定排序：origins 数相同保持到达顺序（对齐原版 Kotlin sortedByDescending
  // 的稳定语义；Dart List.sort 不稳定，须以索引作平局裁决，否则同计数结果乱序）
  // — Qoder UI [fix v2.0.102]
  List<SearchResult> sortedBucket(Map<String, SearchResult> bucket) {
    final values = bucket.values.toList();
    final indexed = <(int, SearchResult)>[
      for (var i = 0; i < values.length; i++) (i, values[i]),
    ];
    indexed.sort((a, b) {
      final byCount = b.$2.originsCount.compareTo(a.$2.originsCount);
      return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
    });
    return indexed.map((e) => e.$2).toList();
  }

  return [
    ...sortedBucket(equal),
    ...sortedBucket(tags),
    ...sortedBucket(contains),
    if (keepOther) ...sortedBucket(other),
  ];
}

/// 书名清洗（对齐原版 `BookHelp.formatBookName` / `AppPattern.nameRegex`）
String formatBookName(String name) {
  return name
      .replaceAll(RegExp(r'\s+作\s*者.*|\s+\S+\s+著'), '')
      .trim();
}

/// 作者清洗（对齐原版 `BookHelp.formatBookAuthor` / `AppPattern.authorRegex`）
String formatBookAuthor(String author) {
  return author
      .replaceAll(RegExp(r'^\s*作\s*者[:：\s]+|\s+著'), '')
      .trim();
}
