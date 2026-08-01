import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'explore_state.freezed.dart';

/// 发现页 UI 状态（immutable）
///
/// 职责边界（对齐 UI_RESTRUCTURE_PLAN.md §0.3 与 ExploreFragment.kt）：
/// - [bookSources]：Rust API 返回的发现书源（仅启用发现且 exploreUrl 非空）
/// - [isLoading] / [error]：API 调用状态
/// - [searchKeyword] / [selectedGroup]：展示层过滤条件（实时搜索 + 分组筛选）
/// - [categoriesCache] / [loadingCategories]：分类解析缓存（对齐 exploreParseUrl）
@freezed
class ExploreState with _$ExploreState {
  const factory ExploreState({
    /// 发现书源列表（已按 Android ExploreFragment 规则过滤：enabledExplore && exploreUrl 非空）
    @Default([]) List<BookSource> bookSources,

    /// 是否正在加载书源列表
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 展示层：实时搜索关键词
    @Default('') String searchKeyword,

    /// 展示层：选中分组（空字符串表示全部）
    @Default('') String selectedGroup,

    /// 分类缓存：sourceUrl → 解析出的分类列表（对齐 exploreParseUrl）
    @Default(<String, List<ExploreCategory>>{})
    Map<String, List<ExploreCategory>> categoriesCache,

    /// 正在加载分类的书源 URL 集合
    @Default(<String>{}) Set<String> loadingCategories,
  }) = _ExploreState;
}

/// 发现页展示扩展 —— 纯展示层变换，不改变数据内容
extension ExploreStateFiltering on ExploreState {
  /// 书源为空且不在加载中
  bool get isEmpty => bookSources.isEmpty && !isLoading;

  /// 所有分组（从书源动态收集，对齐 Android flowExploreGroups）
  Set<String> get groups {
    return bookSources.map((s) => s.groupName ?? '未分类').toSet();
  }

  /// 过滤后的书源列表（关键词 + 分组），仅改变呈现形式
  ///
  /// 对齐 Android ExploreFragment.upExploreData：
  /// - 关键词匹配书名或 URL（不区分大小写）
  /// - 分组精确匹配
  List<BookSource> get filteredBookSources {
    var list = bookSources;
    if (searchKeyword.isNotEmpty) {
      final kw = searchKeyword.toLowerCase();
      list = list.where((s) {
        final name = s.bookSourceName.toLowerCase();
        final url = s.bookSourceUrl.toLowerCase();
        return name.contains(kw) || url.contains(kw);
      }).toList();
    }
    if (selectedGroup.isNotEmpty) {
      list = list.where((s) => s.groupName == selectedGroup).toList();
    }
    return list;
  }

  /// 获取指定书源的分类缓存（null 表示尚未加载）
  List<ExploreCategory>? categoriesFor(String sourceUrl) =>
      categoriesCache[sourceUrl];

  /// 指定书源是否正在加载分类
  bool isLoadingCategories(String sourceUrl) =>
      loadingCategories.contains(sourceUrl);
}
