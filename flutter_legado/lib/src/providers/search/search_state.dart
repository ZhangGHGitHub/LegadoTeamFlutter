import 'package:freezed_annotation/freezed_annotation.dart';

import '../../services/rust_api.dart';

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

    /// 错误信息
    String? error,

    /// 精准搜索：选中的书源 URL
    @Default(<String>{}) Set<String> selectedSourceUrls,

    /// 精准搜索：选中的分组
    @Default(<String>{}) Set<String> selectedGroups,

    /// 搜索历史（最近 20 条，持久化于 SharedPreferences）
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
