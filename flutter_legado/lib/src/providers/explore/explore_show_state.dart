import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'explore_show_state.freezed.dart';

/// 发现分类书籍浏览页路由参数
///
/// 作为 [exploreShowNotifierProvider] 的 family key，需实现值相等，
/// 以保证相同参数命中同一 Notifier 实例、不同参数彼此隔离。
class ExploreShowArgs {
  /// 书源对象
  final BookSource source;

  /// 分类名称
  final String categoryName;

  /// 分类 URL
  final String categoryUrl;

  const ExploreShowArgs({
    required this.source,
    required this.categoryName,
    required this.categoryUrl,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExploreShowArgs &&
          source == other.source &&
          categoryName == other.categoryName &&
          categoryUrl == other.categoryUrl;

  @override
  int get hashCode => Object.hash(source, categoryName, categoryUrl);
}

/// 发现分类书籍 UI 状态（immutable）
///
/// 职责边界（对齐 UI_RESTRUCTURE_PLAN.md §0.3 与 ExploreShowViewModel.kt）：
/// - [source] / [categoryName] / [categoryUrl]：分类页面入参
/// - [books]：累积的书籍列表（对标 Android books LinkedHashSet 去重）
/// - [page] / [isLoading] / [hasMore] / [error]：分页加载状态
@freezed
class ExploreShowState with _$ExploreShowState {
  const factory ExploreShowState({
    /// 当前书源
    BookSource? source,

    /// 分类名称（用于标题显示）
    @Default('') String categoryName,

    /// 分类 URL
    @Default('') String categoryUrl,

    /// 已加载的书籍列表（累积去重）
    @Default([]) List<SearchBook> books,

    /// 当前页码（从 1 开始）
    @Default(1) int page,

    /// 是否正在加载
    @Default(false) bool isLoading,

    /// 是否还有更多数据
    @Default(true) bool hasMore,

    /// 错误信息
    String? error,
  }) = _ExploreShowState;
}

/// 发现分类书籍展示扩展
extension ExploreShowStateTitle on ExploreShowState {
  /// 标题显示：分类名 - 书源名（对标 Android titleBar.title = exploreName）
  String get title {
    final s = source;
    if (s == null) return categoryName;
    return '$categoryName - ${s.bookSourceName}';
  }
}
