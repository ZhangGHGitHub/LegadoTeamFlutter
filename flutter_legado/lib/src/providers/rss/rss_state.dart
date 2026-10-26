import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'rss_state.freezed.dart';

/// 安卓端 AppPattern.splitGroupRegex：[,;，；]
/// 一个源的 sourceGroup 可能是逗号/分号分隔的多个分组
final RegExp _splitGroupRegex = RegExp(r'[,;，；]');

/// RSS UI 状态（immutable）
///
/// 迁移自原 RssProvider（ChangeNotifier），忠实保留全部可观察字段：
/// - [sources]：全部 RSS 源列表
/// - [articles]：当前分类下的文章列表（第 1 页，后续页追加）
/// - [selectedSource]：当前选中的源（null 表示未选中）
/// - [isLoadingSources] / [isLoadingArticles]：源/文章加载状态
/// - [error]：错误信息（null 表示无错误）
/// - [selectedGroup]：当前选中的分组筛选（null 表示「全部」）
///
/// 批15d 新增（对齐原版 `RssSortActivity` + `RssArticlesViewModel`）：
/// - [sorts]：当前源的分类列表（`sortUrl` 解析结果）
/// - [currentSort]：当前选中分类（null 表示未开始加载）
/// - [nextUrl]：下一页地址（null/空表示到底）
/// - [hasMore]：是否还有下一页（对齐原版 LoadMoreView「加载更多/没有更多」）
/// - [loadingMore]：正在加载下一页
/// - [key]：搜索关键词（null 表示非搜索态；对齐原版 `searchKey`）
/// - [page]：当前已加载到的页码（刷新后为 1，加载更多递增）
@freezed
class RssState with _$RssState {
  const factory RssState({
    /// 全部 RSS 源列表
    @Default([]) List<RssSource> sources,

    /// 当前选中源的文章列表
    @Default([]) List<RssFeedArticle> articles,

    /// 当前选中的源（null 表示未选中）
    RssSource? selectedSource,

    /// 是否正在加载源列表
    @Default(false) bool isLoadingSources,

    /// 是否正在加载文章列表
    @Default(false) bool isLoadingArticles,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 当前选中的分组筛选；null 表示「全部」
    String? selectedGroup,

    /// 当前源的分类列表（搜索态为单条「搜索」分类）
    @Default([]) List<RssSort> sorts,

    /// 当前选中分类；null 表示尚未开始加载
    RssSort? currentSort,

    /// 下一页地址（null/空表示没有下一页）
    String? nextUrl,

    /// 是否还有下一页
    @Default(false) bool hasMore,

    /// 是否正在加载下一页
    @Default(false) bool loadingMore,

    /// 加载下一页是否失败（失败后门控，禁止滚动/自动检查连续重发；
    /// 由用户点「重试」或重新刷新后解除，审查 P2-1）
    @Default(false) bool loadMoreFailed,

    /// 搜索关键词；null 表示非搜索态
    String? key,

    /// 当前已加载到的页码（刷新后为 1）
    @Default(1) int page,
  }) = _RssState;
}

/// RSS 展示扩展 —— 纯展示层派生，不改变数据内容
extension RssStateX on RssState {
  /// 源、文章首屏或下一页任一在加载中
  bool get isLoading => isLoadingSources || isLoadingArticles || loadingMore;

  /// 源列表为空且不在加载中
  bool get isEmpty => sources.isEmpty && !isLoadingSources;

  /// 是否处于搜索态（对齐原版 `RssSortActivity.viewModel.searchKey != null`）
  bool get isSearching => key != null && key!.isNotEmpty;

  /// 聚合所有源的分组，去重并保持插入顺序
  /// 对齐安卓 RssFragment 的 linkedSetOf 语义
  List<String> get groups {
    // Dart 的 Set 字面量即 LinkedHashSet，保持插入顺序
    final set = <String>{};
    for (final source in sources) {
      set.addAll(_splitGroups(source.sourceGroup));
    }
    return set.toList();
  }

  /// 按当前选中分组过滤后的源列表；selectedGroup 为 null 时返回全部
  List<RssSource> get filteredSources {
    final group = selectedGroup;
    if (group == null) return sources;
    return sources
        .where((s) => _splitGroups(s.sourceGroup).contains(group))
        .toList();
  }

  /// 将 sourceGroup 字符串按 [,;，；] 拆分、trim、去空
  List<String> _splitGroups(String? sourceGroup) {
    if (sourceGroup == null || sourceGroup.isEmpty) return const [];
    return sourceGroup
        .split(_splitGroupRegex)
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }
}
