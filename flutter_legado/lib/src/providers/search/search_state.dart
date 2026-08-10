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

    /// 搜索结果列表（searchBooks 返回，已按书源聚合）
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

/// 精准搜索过滤 + 分桶排序（严格对齐原版 `SearchModel.mergeItems` 语义）
///
/// 原版两处协同：
/// 1. 源侧 filter（SearchModel.startSearch）：`!precision || name.contains(key)
///    || author.contains(key) || kind?.contains(key) == true`——**包含**匹配而非精确相等；
/// 2. mergeItems：分桶 equal(name==key|author==key) → tags(kind 包含) →
///    contains(name|author 包含) → other，precision 时 **丢弃 other**，
///    最终按 equal→tags→contains→(other) 顺序输出。
///
/// [UI-fix v2.0.10 | 2026-08-10] 原版 mergeItems 无条件执行（默认搜索也按
/// 匹配度分桶排序，仅 other 桶受 precision 开关影响）；修复前仅精准模式
/// 排序、默认模式按书源顺序，与原版不符 — Reasonix
List<SearchResult> applyPrecisionSearch(
  List<SearchResult> results,
  String key, {
  bool keepOther = true,
}) {
  if (key.isEmpty) return results;
  final equal = <SearchResult>[];
  final tags = <SearchResult>[];
  final contains = <SearchResult>[];
  final other = <SearchResult>[];
  for (final r in results) {
    final name = r.book.name;
    final author = r.book.author;
    final kind = r.book.kind ?? '';
    if (name == key || author == key) {
      equal.add(r);
    } else if (kind.contains(key)) {
      tags.add(r);
    } else if (name.contains(key) || author.contains(key)) {
      contains.add(r);
    } else if (keepOther) {
      // 非精准模式：other 桶追加在末尾（对齐原版 mergeItems `else if (!precision)`）
      other.add(r);
    }
  }
  // 原版组内 `sortByDescending { it.origins.size }`（多源聚合后按来源数
  // 降序）；Flutter 侧当前为「先到先得」去重（无聚合），每组内保持到达顺序
  return [...equal, ...tags, ...contains, ...other];
}
