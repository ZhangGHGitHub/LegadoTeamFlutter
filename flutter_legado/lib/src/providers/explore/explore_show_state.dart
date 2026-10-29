import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';
import '../../utils/explore_page_rule.dart';

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
/// - [page] / [displayPage] / [isLoading] / [hasMore] / [error]：分页加载状态
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

    /// 下一待抓取页码（对标 Android ExplorePaginationState.nextPage）
    @Default(1) int page,

    /// 当前展示页码（对标 Android pageLiveData，0 表示尚未完成首次加载）
    @Default(0) int displayPage,

    /// 是否正在加载（首屏/加载更多/跳页共用，不含加载上一页）
    @Default(false) bool isLoading,

    /// 是否正在加载上一页（顶部下拉触发的独立在途标记）
    ///
    /// 与 [isLoading] 分离：加载上一页不推进 [page]，也不改写 [hasMore]，
    /// 两条链路互斥（任一在途时另一侧直接忽略），失败只写 [previousError]。
    @Default(false) bool isLoadingPrevious,

    /// 加载上一页失败的错误信息（顶部条内联重试；不占用 [error]）
    String? previousError,

    /// 是否还有更多数据
    @Default(true) bool hasMore,

    /// 错误信息
    String? error,
  }) = _ExploreShowState;
}

/// 发现列表去重键（对标 Android SearchBook equals 以 bookUrl 为主；
/// bookUrl 为空时回退 name+author）
///
/// [批39 审查回修] 无 bookUrl 且无 author 的书不再使用列表下标（prepend
/// 上一页后下标整体后移，渲染键/锚点键会漂移）——改用「同名书出现序号」
/// （ordinal，由 [exploreBookDedupeKeys] 按列表顺序一次性分配），prepend
/// 只在表头新增条目，已有书的 ordinal 不受影响。
String exploreBookDedupeKey(SearchBook book, {int ordinal = 0}) {
  if (book.bookUrl.isNotEmpty) return 'u:${book.bookUrl}';
  final author = book.author.trim();
  if (author.isNotEmpty) return 'na:${book.name}|$author';
  if (book.name.isNotEmpty) return 'n:${book.name}|$ordinal';
  return 'i:${book.name}|$ordinal';
}

/// 为整表一次性生成去重键（无 URL/无作者书按出现序分配稳定 ordinal）
///
/// 发现列表（Notifier 合并去重）与列表渲染键（GlobalKey/锚点）必须使用
/// 同一套键，否则 prepend 后同一本书在两处得到不同键。
List<String> exploreBookDedupeKeys(List<SearchBook> books) {
  final counters = <String, int>{};
  final keys = <String>[];
  for (final book in books) {
    if (book.bookUrl.isNotEmpty) {
      keys.add(exploreBookDedupeKey(book));
      continue;
    }
    final author = book.author.trim();
    if (author.isNotEmpty) {
      keys.add(exploreBookDedupeKey(book));
      continue;
    }
    // 同名（或无书名的空键位）出现序：按列表顺序递增，与位置无关
    final base = book.name;
    final ordinal = counters[base] ?? 0;
    counters[base] = ordinal + 1;
    keys.add(exploreBookDedupeKey(book, ordinal: ordinal));
  }
  return keys;
}

/// 发现分类书籍展示扩展
extension ExploreShowStateTitle on ExploreShowState {
  /// 标题显示：分类名 - 书源名（对标 Android titleBar.title = exploreName）
  String get title {
    final s = source;
    if (s == null) return categoryName;
    return '$categoryName - ${s.bookSourceName}';
  }

  /// 当前分类 URL 规则是否支持直接指定页码
  ///
  /// 对标参考版 `ExploreShowViewModel`：`canJumpPage =
  /// AnalyzeUrl.supportsPageSelection(kind.url)`；为 false 时顶栏不展示
  /// 页码按钮（规则不支持时页码无法改变请求，跳页无意义）。
  bool get canJumpPage => exploreRuleSupportsPageSelection(categoryUrl);
}
