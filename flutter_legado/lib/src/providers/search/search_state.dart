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

  List<SearchResult> sortedBucket(Map<String, SearchResult> bucket) {
    final list = bucket.values.toList()
      ..sort((a, b) => b.originsCount.compareTo(a.originsCount));
    return list;
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
