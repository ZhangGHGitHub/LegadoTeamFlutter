import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';
import 'rss_state.dart';

export 'rss_state.dart';

/// 对齐 Android `LocalConfig.needUpRssSources` 的版本号
const kRssSourceVersionKey = 'rssSourceVersion';
const kRssSourceVersion = 6;

/// 默认订阅源资源路径（对齐 `app/src/main/assets/defaultData/rssSources.json`）
const kDefaultRssSourcesAsset = 'assets/default_data/rssSources.json';

/// 搜索态分类显示名（对齐原版 `RssSortActivity.upFragments` 的 `"搜索"`）
const kRssSearchSortName = '搜索';

/// 对齐 Android `DefaultData.importDefaultRssSources`：
/// 删除 `sourceGroup == legado` 后灌入 assets 默认源，返回导入条数。
///
/// [jsonOverride] 仅用于单测注入，生产路径传 null 走 assets。
Future<int> syncDefaultRssSources(
  BookApi api, {
  String? jsonOverride,
}) async {
  final existing = await api.getRssSources();
  for (final s in existing.where((e) => e.sourceGroup == 'legado')) {
    await api.deleteRssSource(s.sourceUrl);
  }
  final text = jsonOverride ??
      await rootBundle.loadString(kDefaultRssSourcesAsset);
  return api.importRssSources(text);
}

/// RSS Riverpod Notifier
///
/// 迁移自原 RssProvider（ChangeNotifier）：忠实保留全部方法与错误处理语义，
/// 仅将 `notifyListeners()` 替换为 `state = state.copyWith(...)`。
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理源/文章加载状态（loading/error/data）
/// - 管理分组筛选（对齐安卓 RssFragment）
///
/// 批15d：分类/分页/搜索状态收敛（对齐原版 `RssSortActivity` +
/// `RssArticlesViewModel` + `RssPaginationState`）。UI 只渲染状态，
/// 分类解析、翻页判底、写库等业务全部在 Rust（契约 §2.5）。
class RssNotifier extends Notifier<RssState> {
  /// 当前源的完整分类列表（搜索态下 [RssState.sorts] 只含「搜索」一项，
  /// 退出搜索需用它还原，对齐原版新建 Activity 后返回的分类列表）
  List<RssSort> _sourceSorts = const [];

  /// 进入搜索前选中的分类（退出搜索时优先还原）
  RssSort? _sortBeforeSearch;

  /// 请求序号：切换分类/刷新/搜索时自增，用于丢弃过期响应
  /// （对齐原版 `RssPaginationState.requestSequence`）
  int _requestId = 0;

  @override
  RssState build() {
    // 原 RssProvider 构造时不自动加载，源列表由页面 initState 调用 loadSources 触发
    return const RssState();
  }

  // ===== 源列表操作 =====

  /// 设置分组筛选；null 表示「全部」
  void setGroup(String? group) {
    state = state.copyWith(selectedGroup: group);
  }

  /// 加载所有 RSS 源列表
  Future<void> loadSources() async {
    state = state.copyWith(isLoadingSources: true, error: null);

    try {
      final api = ref.read(bookApiProvider);
      await _ensureDefaultRssSources(api);
      final sources = await api.getRssSources();
      state = state.copyWith(sources: sources, isLoadingSources: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoadingSources: false);
    }
  }

  /// 首启/版本升级时导入默认订阅源（对标 DefaultData.upVersion + importDefaultRssSources）
  Future<void> _ensureDefaultRssSources(BookApi api) async {
    final prefs = await SharedPreferences.getInstance();
    final version = prefs.getInt(kRssSourceVersionKey) ?? 0;
    if (version >= kRssSourceVersion) return;

    await syncDefaultRssSources(api);
    await prefs.setInt(kRssSourceVersionKey, kRssSourceVersion);
  }

  /// 菜单「导入默认」：立即覆盖 legado 分组（对齐 RssSourceViewModel.importDefault）
  Future<int> importDefaultSources() async {
    final api = ref.read(bookApiProvider);
    final n = await syncDefaultRssSources(api);
    final sources = await api.getRssSources();
    state = state.copyWith(sources: sources, error: null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kRssSourceVersionKey, kRssSourceVersion);
    return n;
  }

  // ===== 文章列表操作 =====

  /// 选择源并加载分类与第 1 页文章
  ///
  /// 对齐原版 `RssSortActivity.upFragments`：
  /// 1. `rssSortUrls` 解析分类（失败回退默认单分类 `{name:"", url:sourceUrl}`）；
  /// 2. 选中首个分类，经 `rssRefreshArticles` 刷新第 1 页。
  Future<void> selectSource(RssSource source) async {
    // 分类脚本可能走网络（`@js:`），期间用户提交搜索/切分类时本续体必须
    // 整体丢弃；仅比对 sourceUrl 不足以识别同一源上的新请求代次（P1-1）
    final requestId = ++_requestId;
    state = state.copyWith(
      selectedSource: source,
      isLoadingArticles: true,
      loadingMore: false,
      loadMoreFailed: false,
      error: null,
      articles: const [],
      sorts: const [],
      currentSort: null,
      nextUrl: null,
      hasMore: false,
      key: null,
      page: 1,
    );

    final sorts = await _loadSortsOrFallback(source);
    if (requestId != _requestId) return;
    if (state.selectedSource?.sourceUrl != source.sourceUrl) return;
    _sourceSorts = sorts;
    _sortBeforeSearch = null;
    final sort = sorts.first;

    state = state.copyWith(sorts: sorts, currentSort: sort);
    await _refreshPage(source, sort, null, clearArticles: true);
  }

  /// 切换分类（对齐原版 ViewPager 换页：重建 Fragment 并加载第 1 页）
  Future<void> selectSort(RssSort sort) async {
    final source = state.selectedSource;
    if (source == null) return;
    // 原版重复点击同一 tab 不重新加载
    if (state.currentSort == sort) return;
    state = state.copyWith(currentSort: sort);
    await _refreshPage(source, sort, state.key, clearArticles: true);
  }

  /// 刷新当前分类的第 1 页（下拉刷新；保留旧列表直到新数据返回）
  Future<void> refreshArticles() async {
    final source = state.selectedSource;
    final sort = state.currentSort;
    if (source == null || sort == null) return;
    await _refreshPage(source, sort, state.key, clearArticles: false);
  }

  /// 加载下一页（触底自动触发；对齐原版 `RssArticlesViewModel.loadMore`）
  ///
  /// 无下一页（`!hasMore` / `nextUrl` 空）、在途请求、或上次加载失败
  /// （[RssState.loadMoreFailed]）时直接返回；失败门控避免滚动/首屏自动
  /// 检查连续重发同一失败请求（审查 P2-1）。
  Future<void> loadMore() async {
    final source = state.selectedSource;
    final sort = state.currentSort;
    if (source == null || sort == null) return;
    if (state.isLoadingArticles ||
        state.loadingMore ||
        state.loadMoreFailed ||
        !state.hasMore) {
      return;
    }
    final nextUrl = (state.nextUrl ?? '').trim();
    if (nextUrl.isEmpty) return;

    // 不增加请求序号：加载更多属于当前刷新代次，若期间发生刷新/切换分类，
    // 序号变化会使本页结果被丢弃（`_refreshPage` 起始处会自增）。
    final requestId = _requestId;
    final nextPage = state.page + 1;
    state = state.copyWith(loadingMore: true, error: null);
    try {
      final json = await ref.read(bookApiProvider).rssLoadMoreArticles(
            source.sourceUrl,
            sort.name,
            nextUrl,
            nextPage,
            key: state.key,
          );
      if (requestId != _requestId) return;
      final page = _parseArticlesPage(json);
      // 对齐 Rust `INSERT OR IGNORE`：同分类同链接的重复条目不再追加
      final seen = <String>{for (final a in state.articles) _articleKey(a)};
      final merged = <RssFeedArticle>[...state.articles];
      for (final article in page.articles) {
        if (seen.add(_articleKey(article))) merged.add(article);
      }
      state = state.copyWith(
        articles: merged,
        nextUrl: page.nextUrl,
        hasMore: page.hasMore,
        loadingMore: false,
        loadMoreFailed: false,
        page: nextPage,
        error: null,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        loadingMore: false,
        loadMoreFailed: true,
        error: _mapError(e),
      );
    }
  }

  /// 用户点「重试」：解除加载更多失败门控后重发同一页（审查 P2-1）
  Future<void> retryLoadMore() async {
    if (!state.loadMoreFailed) return;
    state = state.copyWith(loadMoreFailed: false, error: null);
    await loadMore();
  }

  /// 搜索（对齐原版 `menu_search`：以 `searchUrl` 为分类、关键词为 key 刷新）
  ///
  /// 空关键词等价退出搜索（还原进入搜索前的分类并刷新默认列表）。
  /// 源未配置 `searchUrl` 时直接返回（UI 不显示搜索入口）。
  Future<void> search(String key) async {
    final source = state.selectedSource;
    if (source == null) return;
    final normalized = key.trim();
    if (normalized.isEmpty) {
      await clearSearch();
      return;
    }
    final searchUrl = (source.searchUrl ?? '').trim();
    if (searchUrl.isEmpty) return;

    if (state.key == null) _sortBeforeSearch = state.currentSort;
    final sort = RssSort(name: kRssSearchSortName, url: searchUrl);
    state = state.copyWith(key: normalized, sorts: [sort], currentSort: sort);
    await _refreshPage(source, sort, normalized, clearArticles: true);
  }

  /// 退出搜索：还原搜索前的分类（缺失时回退首个分类）并刷新
  Future<void> clearSearch() async {
    final source = state.selectedSource;
    if (source == null || state.key == null) return;

    // 分类列表缺失时需要重新解析（可能走网络脚本），期间再次提交搜索
    // 或切换源必须丢弃本续体（P1-1）
    final requestId = ++_requestId;
    var sorts = _sourceSorts;
    if (sorts.isEmpty) {
      sorts = await _loadSortsOrFallback(source);
      if (requestId != _requestId) return;
      if (state.selectedSource?.sourceUrl != source.sourceUrl) return;
      _sourceSorts = sorts;
    }
    final preferred = _sortBeforeSearch;
    final sort = (preferred != null && sorts.contains(preferred))
        ? preferred
        : sorts.first;
    _sortBeforeSearch = null;
    state = state.copyWith(key: null, sorts: sorts, currentSort: sort);
    await _refreshPage(source, sort, null, clearArticles: true);
  }

  /// 刷新分类（菜单「刷新排序」）
  ///
  /// 对齐原版 `menu_refresh_sort`：`clearSortCache` 后重新 `sortUrls`，
  /// 再刷新当前分类列表；搜索态不重新解析分类，只重拉搜索结果
  /// （对齐原版 `upFragments` 的 `searchKey != null` 分支，审查 P2-4）。
  Future<void> refreshSorts() async {
    final source = state.selectedSource;
    if (source == null) return;
    final requestId = ++_requestId;
    state = state.copyWith(error: null);
    final api = ref.read(bookApiProvider);
    try {
      await api.rssClearSortCache(source.sourceUrl);
    } catch (_) {
      // 缓存清理失败不阻断重新解析（对齐原版 removeSortCache 静默语义）
    }
    if (requestId != _requestId) return;
    if (state.selectedSource?.sourceUrl != source.sourceUrl) return;

    if (state.key != null) {
      // 搜索态：保持「搜索」分类，仅重拉结果（原版搜索分支不调 sortUrls）
      await refreshArticles();
      return;
    }

    List<RssSort> sorts;
    try {
      sorts = await _fetchSorts(source);
    } catch (e) {
      if (requestId != _requestId) return;
      if (state.selectedSource?.sourceUrl != source.sourceUrl) return;
      state = state.copyWith(error: _mapError(e));
      return;
    }
    if (requestId != _requestId) return;
    if (state.selectedSource?.sourceUrl != source.sourceUrl) return;
    _sourceSorts = sorts;

    final preferred = state.currentSort;
    final sort = (preferred != null && sorts.contains(preferred))
        ? preferred
        : sorts.first;
    state = state.copyWith(sorts: sorts, currentSort: sort);
    await _refreshPage(source, sort, null, clearArticles: true);
  }

  /// 清除已选源（返回源列表）
  void clearSelectedSource() {
    _requestId++;
    _sourceSorts = const [];
    _sortBeforeSearch = null;
    state = state.copyWith(
      selectedSource: null,
      articles: const [],
      sorts: const [],
      currentSort: null,
      nextUrl: null,
      hasMore: false,
      loadingMore: false,
      loadMoreFailed: false,
      isLoadingArticles: false,
      key: null,
      page: 1,
      error: null,
    );
  }

  // ===== 源增删 =====

  /// 添加 RSS 源
  Future<void> addSource(String name, String url) async {
    state = state.copyWith(error: null);

    try {
      final newSource = RssSource(
        sourceUrl: url,
        sourceName: name,
      );
      final api = ref.read(bookApiProvider);
      final added = await api.addRssSource(newSource);
      state = state.copyWith(sources: [...state.sources, added]);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 删除 RSS 源
  Future<void> removeSource(String sourceUrl) async {
    state = state.copyWith(error: null);

    try {
      final api = ref.read(bookApiProvider);
      await api.deleteRssSource(sourceUrl);
      var next = state.copyWith(
        sources:
            state.sources.where((s) => s.sourceUrl != sourceUrl).toList(),
      );
      if (state.selectedSource?.sourceUrl == sourceUrl) {
        // 对齐原 clearSelectedSource：清除选中源与文章相关状态
        _requestId++;
        _sourceSorts = const [];
        _sortBeforeSearch = null;
        next = next.copyWith(
          selectedSource: null,
          articles: const [],
          sorts: const [],
          currentSort: null,
          nextUrl: null,
          hasMore: false,
          loadingMore: false,
          loadMoreFailed: false,
          isLoadingArticles: false,
          key: null,
          page: 1,
        );
      }
      state = next;
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 清除错误
  void clearError() {
    state = state.copyWith(error: null);
  }

  // ===== 内部实现 =====

  /// 刷新第 1 页并写入状态（过期响应按请求序号丢弃）
  Future<void> _refreshPage(
    RssSource source,
    RssSort sort,
    String? key, {
    required bool clearArticles,
  }) async {
    final requestId = ++_requestId;
    state = state.copyWith(
      isLoadingArticles: true,
      loadingMore: false,
      loadMoreFailed: false,
      error: null,
      articles: clearArticles ? const [] : state.articles,
      nextUrl: null,
      hasMore: false,
      page: 1,
    );
    try {
      final json = await ref.read(bookApiProvider).rssRefreshArticles(
            source.sourceUrl,
            sort.name,
            sort.url,
            key: key,
          );
      if (requestId != _requestId) return;
      final page = _parseArticlesPage(json);
      state = state.copyWith(
        articles: page.articles,
        nextUrl: page.nextUrl,
        hasMore: page.hasMore,
        isLoadingArticles: false,
        page: 1,
        error: null,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(isLoadingArticles: false, error: _mapError(e));
    }
  }

  /// 解析分类列表（失败由调用方决定回退）
  Future<List<RssSort>> _fetchSorts(RssSource source) async {
    final json = await ref.read(bookApiProvider).rssSortUrls(source.sourceUrl);
    final decoded = jsonDecode(json);
    if (decoded is! List) {
      throw const FormatException('rssSortUrls 期望 JSON 数组');
    }
    final sorts = <RssSort>[];
    for (final item in decoded) {
      // 形态不符必须显式（防复发规定 §4）：FFI 契约恒为对象数组
      if (item is! Map) {
        throw const FormatException('rssSortUrls 项期望 JSON 对象');
      }
      final sort = RssSort.fromJson(Map<String, dynamic>.from(item));
      if (sort.url.isEmpty) {
        throw const FormatException('rssSortUrls 项缺少 url');
      }
      sorts.add(sort);
    }
    if (sorts.isEmpty) return _defaultSorts(source);
    return sorts;
  }

  /// 分类加载失败回退默认单分类（对齐原版 `sortUrls()` 无配置回退）
  Future<List<RssSort>> _loadSortsOrFallback(RssSource source) async {
    try {
      return await _fetchSorts(source);
    } catch (_) {
      return _defaultSorts(source);
    }
  }

  List<RssSort> _defaultSorts(RssSource source) =>
      [RssSort(name: '', url: source.sourceUrl)];

  /// 解析 `rssRefreshArticles` / `rssLoadMoreArticles` 的 JSON 载荷
  _RssArticlesPage _parseArticlesPage(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('RSS 列表载荷期望 JSON 对象');
    }
    final articles = <RssFeedArticle>[];
    final rawArticles = decoded['articles'];
    if (rawArticles != null && rawArticles is! List) {
      // 形态不符必须显式（防复发规定 §4）：契约恒为数组
      throw const FormatException('RSS 列表 articles 期望 JSON 数组');
    }
    if (rawArticles is List) {
      for (final item in rawArticles) {
        if (item is! Map) {
          throw const FormatException('RSS 列表项期望 JSON 对象');
        }
        articles.add(RssFeedArticle.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    final nextUrl = (decoded['nextUrl'] as String?)?.trim() ?? '';
    return _RssArticlesPage(
      articles: articles,
      nextUrl: nextUrl.isEmpty ? null : nextUrl,
      // 对齐契约：hasMore = 本页有新增且 nextUrl 非空
      hasMore: decoded['hasMore'] == true && nextUrl.isNotEmpty,
    );
  }

  /// 列表去重键（对齐 DB 主键 `(origin, sort, link)`；UI 侧可省 origin）
  String _articleKey(RssFeedArticle article) =>
      '${article.sort}\u0000${article.url}';

  /// 统一错误映射（对齐原 BridgeError 优先取 message）
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// RSS 列表分页载荷（Rust `{articles,nextUrl,hasMore}` 的 Dart 形态）
class _RssArticlesPage {
  final List<RssFeedArticle> articles;
  final String? nextUrl;
  final bool hasMore;

  const _RssArticlesPage({
    required this.articles,
    required this.nextUrl,
    required this.hasMore,
  });
}

/// RSS Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(rssNotifierProvider);
/// ref.read(rssNotifierProvider.notifier).loadSources();
/// ```
final rssNotifierProvider = NotifierProvider<RssNotifier, RssState>(
  RssNotifier.new,
);
