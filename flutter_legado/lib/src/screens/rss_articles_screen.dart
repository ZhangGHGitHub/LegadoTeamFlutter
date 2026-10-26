import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/rss/rss_notifier.dart';
import '../providers/rss_history/rss_history_notifier.dart';
import '../widgets/custom_refresh_indicator.dart'; // [LAYOUT_PLAN P4] 下拉 M3 化
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_article_detail_screen.dart';
import 'rss_source_edit_screen.dart';
import 'source_login_screen.dart';

/// RSS 文章列表页面
///
/// 批15d：分类 Tab / 触底加载更多 / 搜索入口收敛（对齐原版
/// `RssSortActivity` + `RssArticlesFragment`，视觉对齐参考版 `RssSortScreen`
/// 的顶栏 TabRow 形态）。本页只渲染 [RssState] 与派发命令，分类解析、
/// 翻页判底、写库等业务全部在 Rust（契约 §2.5）。
class RssArticlesScreen extends ConsumerStatefulWidget {
  final RssSource source;

  const RssArticlesScreen({super.key, required this.source});

  @override
  ConsumerState<RssArticlesScreen> createState() => _RssArticlesScreenState();
}

class _RssArticlesScreenState extends ConsumerState<RssArticlesScreen>
    with TickerProviderStateMixin {
  final Set<String> _readArticles = {};

  /// 详情页规则正文抓取成功后的内存回填（审查 P2-7）
  ///
  /// Rust `rssFetchContent` 已把正文写回 `rssArticles.description`，但列表页
  /// 当前无「只读 DB」FFI（`getRssArticles` 是网络刷新，会用 feed 摘要
  /// REPLACE 覆盖刚抓到的正文），故由详情页回调把正文带回列表内存态；
  /// 返回列表立即可见，DB 仍是真源（列表页 DB-only 查询改挂后续批次，
  /// 批15d 审查 P2-7）。
  final Map<String, String> _fetchedDescriptions = {};

  // [UI-fix v2.0.2 | 2026-08-06] 布局切换本地态（对标原版 articleStyle 0-4
  // 循环；Flutter 端支持两种渲染：0=列表，其他=双列网格） — Qoder
  late int _articleStyle = widget.source.articleStyle;

  /// 分类 Tab 控制器（分类数变化时重建；对齐 bookshelf 分组 Tab 做法）
  TabController? _tabController;
  int _tabControllerLength = 0;

  /// 列表滚动控制器（触底自动加载更多）
  final ScrollController _scrollController = ScrollController();

  /// 已触发首屏自动加载的列表签名（分类|关键词|条数）
  ///
  /// 首屏不足一屏时不会产生滚动事件，需要布局完成后主动做一次阈值判断
  /// （对齐参考版 LoadMoreDetector 的初始发射）；签名避免同一列表状态
  /// 被重复发射，失败时由 [RssState.loadMoreFailed] 门控（审查 P1-2/P2-1）。
  int? _autoLoadSignature;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 加载分类与文章
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssNotifierProvider.notifier).selectSource(widget.source);
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _tabController?.removeListener(_onTabControllerChanged);
    _tabController?.dispose();
    super.dispose();
  }

  // ===== 分类 Tab =====

  /// 按分类数量维护 TabController（分类数变化时重建）
  TabController _ensureTabController(int length) {
    if (_tabController == null || _tabControllerLength != length) {
      _tabController?.removeListener(_onTabControllerChanged);
      _tabController?.dispose();
      _tabController = TabController(length: length, vsync: this);
      _tabController!.addListener(_onTabControllerChanged);
      _tabControllerLength = length;
    }
    return _tabController!;
  }

  /// Tab 切换 → 通知分类选择（对齐原版 ViewPager.onPageSelected）
  void _onTabControllerChanged() {
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    final state = ref.read(rssNotifierProvider);
    if (state.isSearching || state.sorts.length <= 1) return;
    if (controller.index >= state.sorts.length) return;
    final sort = state.sorts[controller.index];
    if (state.currentSort != sort) {
      ref.read(rssNotifierProvider.notifier).selectSort(sort);
    }
  }

  /// 状态选中分类 → 帧后同步到 TabController（避免 build 期间改动）
  void _syncTabControllerIndex(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _tabController;
      if (!mounted || controller == null) return;
      if (controller.index != index && index < controller.length) {
        controller.animateTo(index);
      }
    });
  }

  /// 分类 Tab 行（单分类时隐藏，对齐原版 `upFragmentsView` 的 gone 分支）
  PreferredSizeWidget? _buildSortTabs(RssState state) {
    final sorts = state.sorts;
    if (sorts.length <= 1) return null;
    final controller = _ensureTabController(sorts.length);
    _syncTabControllerIndex(_currentSortIndex(state));
    final colorScheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context)
        .textTheme
        .labelLarge
        ?.copyWith(fontWeight: FontWeight.w500);
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: SizedBox(
        width: double.infinity,
        child: TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.only(left: 12),
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          dividerColor: Colors.transparent,
          dividerHeight: 0,
          labelColor: colorScheme.primary,
          unselectedLabelColor: colorScheme.onSurfaceVariant,
          labelStyle: labelStyle,
          unselectedLabelStyle: labelStyle,
          tabs: [
            for (final sort in sorts)
              Tab(text: sort.name.isEmpty ? '默认' : sort.name),
          ],
        ),
      ),
    );
  }

  int _currentSortIndex(RssState state) {
    final current = state.currentSort;
    if (current == null) return 0;
    final index = state.sorts.indexOf(current);
    return index < 0 ? 0 : index;
  }

  // ===== 加载更多 =====

  /// 触底检测：距底部 240dp 内触发加载下一页（通知器内部幂等防重）
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      ref.read(rssNotifierProvider.notifier).loadMore();
    }
  }

  /// 首屏/列表增长后的补一次触底判断（纯滚动触发在不足一屏时失效）
  ///
  /// `maxScrollExtent <= 0` 时视口未填满，同样命中阈值；加载更多失败后
  /// 由 [RssState.loadMoreFailed] 拦住，等待用户点「重试」。
  void _maybeAutoLoadMore() {
    if (!mounted || !_scrollController.hasClients) return;
    final state = ref.read(rssNotifierProvider);
    if (state.articles.isEmpty ||
        state.isLoadingArticles ||
        state.loadingMore ||
        state.loadMoreFailed ||
        !state.hasMore) {
      return;
    }
    final signature = Object.hash(
      state.currentSort?.name,
      state.key,
      state.articles.length,
    );
    if (_autoLoadSignature == signature) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 240) return;
    _autoLoadSignature = signature;
    ref.read(rssNotifierProvider.notifier).loadMore();
  }

  /// 列表底部加载更多指示（对齐原版 LoadMoreView：加载中 / 已经到底了）
  ///
  /// 审查 P2-1/P2-2：刷新中隐藏 footer；加载更多失败显示错误 + 重试；
  /// 刷新失败同样显示错误态，避免误显「已经到底了~」。
  Widget _buildLoadMoreFooter(RssState state) {
    final theme = Theme.of(context);
    final notifier = ref.read(rssNotifierProvider.notifier);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // 刷新中：旧列表保留，下拉指示器已承担反馈
    if (state.isLoadingArticles) return const SizedBox.shrink();

    if (state.loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                state.error ?? '加载更多失败',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
            TextButton(
              onPressed: notifier.retryLoadMore,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (state.loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              '加载中…',
              style: labelStyle,
            ),
          ],
        ),
      );
    }

    // 刷新失败（列表保留旧数据）：错误 + 重试，不误显「已经到底了~」
    if (state.error != null && state.articles.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                state.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
            TextButton(
              onPressed: notifier.refreshArticles,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 有下一页时提供可点击兜底（滚动监听失效/不足一屏时仍可手动加载）
    if (state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: TextButton(
            onPressed: notifier.loadMore,
            child: const Text('加载更多'),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text('已经到底了~', style: labelStyle),
      ),
    );
  }

  // ===== 页面 =====

  /// 顶栏标题（对齐原版 `upFragmentsView`：搜索态显示关键词；
  /// 单分类且分类名非空时显示分类名；否则显示源名）
  String _screenTitle(RssState state) {
    if (state.isSearching) return state.key!;
    final sorts = state.sorts;
    if (sorts.length == 1 && sorts.first.name.isNotEmpty) {
      return sorts.first.name;
    }
    return widget.source.sourceName;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssNotifierProvider);
    final notifier = ref.read(rssNotifierProvider.notifier);
    final hasSearch = (widget.source.searchUrl ?? '').trim().isNotEmpty;

    // 刷新/加载更多失败：列表已有内容时用 SnackBar 提示（空列表由 ErrorView 呈现）
    ref.listen<String?>(rssNotifierProvider.select((s) => s.error),
        (previous, next) {
      if (!mounted || next == null || next == previous) return;
      if (ref.read(rssNotifierProvider).articles.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(next)),
      );
    });

    // 首屏不足一屏时没有滚动事件：布局完成后补一次触底判断
    // （对齐参考版 LoadMoreDetector 初始发射，审查 P1-2）
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoLoadMore());
    // 新一轮刷新开始后允许重新做首屏自动加载判断（列表可能再次不足一屏）
    ref.listen<bool>(
      rssNotifierProvider.select((s) => s.isLoadingArticles),
      (previous, next) {
        if (next) _autoLoadSignature = null;
      },
    );

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    final scaffold = AppScaffold(
      topBar: LegadoAppBar(
        title: Text(_screenTitle(state)),
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios_new_rounded),
          tooltip: state.isSearching ? '退出搜索' : '返回',
          onPressed: () {
            // 对齐原版返回键：搜索态先退出搜索，非搜索态返回列表
            if (state.isSearching) {
              notifier.clearSearch();
              return;
            }
            notifier.clearSelectedSource();
            Navigator.pop(context);
          },
        ),
        // 分类 Tab：单分类隐藏
        bottom: _buildSortTabs(state),
        actions: [
          // 搜索入口：仅源配置 searchUrl 时显示（对齐 RssSortActivity.kt:271-284）
          if (hasSearch)
            IconButton(
              icon: const Icon(Symbols.search_rounded),
              tooltip: '搜索',
              onPressed: _showSearchDialog,
            ),
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => notifier.refreshArticles(),
          ),
          // [UI-fix v2.0.2 | 2026-08-06] 文章列表菜单（对标原版
          // rss_articles.xml：登录/刷新排序/设置源变量/编辑源/切换布局/
          // 阅读记录/清空；搜索入口另位于顶栏） — Qoder
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleMenu,
            itemBuilder: (_) => [
              // 对标原版 onMenuOpened：仅 loginUrl 非空时显示登录
              if ((widget.source.loginUrl ?? '').trim().isNotEmpty)
                const PopupMenuItem(value: 'login', child: Text('登录')),
              const PopupMenuItem(value: 'refreshSort', child: Text('刷新排序')),
              const PopupMenuItem(
                value: 'setVariable',
                child: Text('设置源变量'),
              ),
              const PopupMenuItem(value: 'editSource', child: Text('编辑源')),
              const PopupMenuItem(value: 'switchLayout', child: Text('切换布局')),
              const PopupMenuItem(value: 'readRecord', child: Text('阅读记录')),
              const PopupMenuItem(value: 'clear', child: Text('清空')),
            ],
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (state.isLoadingArticles && state.articles.isEmpty) {
            return const LoadingIndicator(message: '加载文章...');
          }

          if (state.error != null && state.articles.isEmpty) {
            return ErrorView(
              message: state.error!,
              onRetry: () => notifier.refreshArticles(),
            );
          }

          if (state.articles.isEmpty) {
            return const EmptyState(
              icon: Symbols.article_rounded,
              title: '暂无文章',
              subtitle: '下拉刷新获取最新内容',
            );
          }

          // [LAYOUT_PLAN P4] 下拉 M3 化：裸 RefreshIndicator → CustomRefreshIndicator
          return CustomRefreshIndicator(
            onRefresh: () => notifier.refreshArticles(),
            child: _articleStyle == 0
                ? ListView.separated(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    // 末尾附加加载更多指示行（对齐原版 LoadMoreView）
                    itemCount: state.articles.length + 1,
                    // iOS 风格：分隔线从文字列起始处缩进（16 边距 + 80 缩略图 + 12 间距）
                    separatorBuilder: (c, i) => i >= state.articles.length - 1
                        ? const SizedBox.shrink()
                        : const Divider(height: 1, indent: 108, endIndent: 16),
                    itemBuilder: (context, index) {
                      if (index == state.articles.length) {
                        return _buildLoadMoreFooter(state);
                      }
                      final article = state.articles[index];
                      final isRead = _readArticles.contains(article.url);
                      return _buildArticleItem(context, article, isRead);
                    },
                  )
                // [UI-fix v2.0.2 | 2026-08-06] 布局切换：双列网格渲染 — Qoder
                : CustomScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.all(12),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.72,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final article = state.articles[index];
                              final isRead =
                                  _readArticles.contains(article.url);
                              return _buildGridItem(context, article, isRead);
                            },
                            childCount: state.articles.length,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _buildLoadMoreFooter(state),
                      ),
                    ],
                  ),
          );
        },
      ),
    );

    // 对齐原版 `onBackPressedDispatcher`：搜索态系统返回先退出搜索而非退页
    return PopScope(
      canPop: !state.isSearching,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (ref.read(rssNotifierProvider).isSearching) {
          ref.read(rssNotifierProvider.notifier).clearSearch();
        }
      },
      child: scaffold,
    );
  }

  Widget _buildArticleItem(
      BuildContext context, RssFeedArticle article, bool isRead) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 详情页抓取成功后回填的正文优先于列表摘要（审查 P2-7）
    final description =
        _fetchedDescriptions[article.url] ?? article.description;

    // 稳定 ValueKey（文章 url）+ RepaintBoundary 隔离列表项重绘区域
    final item = InkWell(
      key: ValueKey(article.url),
      onTap: () {
        setState(() => _readArticles.add(article.url));
        _openDetail(article);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图（iOS 风格 10 圆角）
            if (article.imageUrl != null && article.imageUrl!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CachedNetworkImage(
                  imageUrl: article.imageUrl!,
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                  // 限制解码宽度为缩略图实际显示像素宽度（80），避免大图解码
                  memCacheWidth: (80 *
                          (MediaQuery.maybeOf(context)?.devicePixelRatio ??
                              1.0))
                      .round(),
                  placeholder: (_, _) => Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  errorWidget: (_, _, _) => Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Symbols.image_not_supported_rounded,
                        color: colorScheme.onSurfaceVariant.withAlpha(128)),
                  ),
                ),
              )
            else
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Symbols.article_rounded,
                    color: colorScheme.onSurfaceVariant.withAlpha(128)),
              ),
            const SizedBox(width: 12),
            // 文字内容
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isRead
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (description != null && description.isNotEmpty)
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Symbols.schedule_rounded,
                          size: 12, color: colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      // 宽时间戳（ISO-8601）在窄屏下可能溢出：Flexible 收缩 + 省略号
                      Flexible(
                        child: Text(
                          article.pubDate ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (isRead) ...[
                        const SizedBox(width: 8),
                        Icon(Symbols.check_circle_rounded,
                            size: 12, color: colorScheme.primary),
                        const SizedBox(width: 2),
                        Text(
                          '已读',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return RepaintBoundary(child: item);
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 菜单处理（对标 rss_articles.xml）— Qoder =====

  /// 搜索（对齐原版 menu_search 的 SearchView 提交：以源 searchUrl 搜索）
  Future<void> _showSearchDialog() async {
    final notifier = ref.read(rssNotifierProvider.notifier);
    final submitted = await showDialog<String>(
      context: context,
      builder: (_) => _RssSearchDialog(
        initialQuery: ref.read(rssNotifierProvider).key ?? '',
      ),
    );
    if (submitted == null) return;
    await notifier.search(submitted);
  }

  /// 打开文章详情（同时经 rss FFI 标记已读）
  void _openDetail(RssFeedArticle article) {
    // [UI-fix v2.0.2 | 2026-08-06] 接通 rssMarkRead FFI（对标原版
    // RssReadViewModel.recordRead），失败不阻断阅读 — Qoder
    ref
        .read(bookApiProvider)
        .rssMarkRead(widget.source.sourceUrl, article.title, article.url)
        .catchError((_) {});
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RssArticleDetailScreen(
          article: article,
          sourceName: widget.source.sourceName,
          sourceUrl: widget.source.sourceUrl,
          // 审查 P2-7：详情页抓到规则正文后回填列表内存态
          onContentFetched: (description) {
            if (!mounted) return;
            setState(() => _fetchedDescriptions[article.url] = description);
          },
        ),
      ),
    ).then((_) {
      // 从详情返回列表时刷新一次：详情在途期间可能已回填正文/标记已读。
      // 注：列表无 DB-only 查询 FFI（getRssArticles 为网络刷新），故这里
      // 按内存回填刷新；DB 真源由 Rust 写回。
      if (mounted) setState(() {});
    });
  }

  /// 网格布局文章项（布局切换 articleStyle≠0 时使用）
  Widget _buildGridItem(
    BuildContext context,
    RssFeedArticle article,
    bool isRead,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          setState(() => _readArticles.add(article.url));
          _openDetail(article);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: article.imageUrl != null && article.imageUrl!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: article.imageUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: 300,
                      placeholder: (_, _) =>
                          Container(color: colorScheme.surfaceContainerHighest),
                      errorWidget: (_, _, _) => Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Symbols.image_not_supported_rounded,
                          color: colorScheme.onSurfaceVariant.withAlpha(128),
                        ),
                      ),
                    )
                  : Container(
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Symbols.article_rounded,
                        color: colorScheme.onSurfaceVariant.withAlpha(128),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isRead
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                    ),
                  ),
                  if (article.pubDate != null &&
                      article.pubDate!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      article.pubDate!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 菜单分发（7 项）
  void _handleMenu(String value) {
    switch (value) {
      case 'login':
        // 对标原版 menu_login → SourceLoginActivity(type=rssSource)
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SourceLoginScreen(
              sourceUrl: widget.source.sourceUrl,
              sourceName: widget.source.sourceName,
              loginUrl: widget.source.loginUrl,
            ),
          ),
        );
      case 'refreshSort':
        // 对标原版 menu_refresh_sort：清分类脚本缓存后重新解析分类，
        // 再刷新当前分类列表（批15d 替代旧「重新拉列表」伪实现）
        ref.read(rssNotifierProvider.notifier).refreshSorts();
      case 'setVariable':
        _showSetVariableDialog();
      case 'editSource':
        // 对标原版 menu_edit_source → RssSourceEditActivity
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RssSourceEditScreen(source: widget.source),
          ),
        );
      case 'switchLayout':
        _switchLayout();
      case 'readRecord':
        // 对标原版 menu_read_record → ReadRecordDialog(sourceUrl)
        showDialog<void>(
          context: context,
          builder: (_) => _RssReadRecordDialog(origin: widget.source.sourceUrl),
        );
      case 'clear':
        _clearArticles();
    }
  }

  /// 设置源变量（对标原版 VariableDialog + BaseSource.setVariable）
  ///
  /// 持久化键对齐 Kotlin CacheManager：`sourceVariable_${getKey()}`，经 config FFI。
  Future<void> _showSetVariableDialog() async {
    final api = ref.read(bookApiProvider);
    final key = 'sourceVariable_${widget.source.sourceUrl}';
    String? initial;
    try {
      initial = await api.getConfig(key);
      if (initial == null || initial.isEmpty) {
        initial = await api.getConfig(
          'rssSourceVariable_${widget.source.sourceUrl}',
        );
      }
    } catch (_) {}
    if (!mounted) return;
    final ctrl = TextEditingController(text: initial ?? '');
    final comment = (widget.source.variableComment ?? '').isEmpty
        ? '源变量可在 JS 中通过 source.getVariable() 获取'
        : widget.source.variableComment!;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置源变量'),
        content: TextField(
          controller: ctrl,
          autofocus: false,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: comment,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    try {
      if (result.isEmpty) {
        await api.deleteConfig(key);
      } else {
        await api.setConfig(key, result);
      }
      try {
        await api.deleteConfig('rssSourceVariable_${widget.source.sourceUrl}');
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('源变量已保存')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存源变量失败：$e')),
        );
      }
    }
  }

  /// 切换布局（对标原版 switchLayout：articleStyle 0-4 循环后持久化）
  Future<void> _switchLayout() async {
    final next = _articleStyle >= 4 ? 0 : _articleStyle + 1;
    setState(() => _articleStyle = next);
    final updated = widget.source.copyWith(articleStyle: next);
    try {
      await ref.read(bookApiProvider).updateRssSource(updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('布局保存失败：$e')),
        );
      }
    }
  }

  /// 清空（对标原版 menu_clear → clearArticles 删本源本地缓存文章）
  Future<void> _clearArticles() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空'),
        content: const Text('将清空本源本地缓存的文章列表，确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(bookApiProvider).rssClearArticles(widget.source.sourceUrl);
      ref.read(rssNotifierProvider.notifier).refreshArticles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本源文章缓存已清空')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空失败：$e')),
        );
      }
    }
  }
}

/// 搜索关键词输入对话框（对齐原版 `SearchView` 提交语义）
///
/// 自持有 [TextEditingController]，随对话框路由销毁而释放（避免在
/// `showDialog` 返回后立即 dispose 导致退出动画期间使用已释放控制器）。
class _RssSearchDialog extends StatefulWidget {
  final String initialQuery;

  const _RssSearchDialog({required this.initialQuery});

  @override
  State<_RssSearchDialog> createState() => _RssSearchDialogState();
}

class _RssSearchDialogState extends State<_RssSearchDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('搜索'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: '输入搜索关键词',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('搜索'),
        ),
      ],
    );
  }
}

/// [UI-fix v2.0.2 | 2026-08-06] 阅读记录对话框（对标原版 ReadRecordDialog：
/// 展示并跳转本源已读记录，经 rssHistoryNotifier 拉取后按 origin 过滤）— Qoder
class _RssReadRecordDialog extends ConsumerStatefulWidget {
  final String origin;

  const _RssReadRecordDialog({required this.origin});

  @override
  ConsumerState<_RssReadRecordDialog> createState() =>
      _RssReadRecordDialogState();
}

class _RssReadRecordDialogState extends ConsumerState<_RssReadRecordDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(rssHistoryNotifierProvider.notifier)
          .load(origin: widget.origin);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssHistoryNotifierProvider);
    final records = state.records;
    return AlertDialog(
      title: const Text('阅读记录'),
      content: SizedBox(
        width: double.maxFinite,
        child: state.isLoading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            : state.error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(state.error!),
                    ),
                  )
                : records.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('暂无阅读记录'),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: records.length,
                        itemBuilder: (context, index) {
                          final record = records[index];
                          final time = DateTime.fromMillisecondsSinceEpoch(
                            record.readTime,
                          );
                          return ListTile(
                            dense: true,
                            // 审查 P2-6：条目可点击重读，透传 origin 使
                            // 详情页规则正文抓取/收藏 origin 生效
                            onTap: () => _openRecord(record),
                            title: Text(
                              record.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                            ),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 点击记录重读（同列表页历史入口：透传 origin，legacy/空链接不传）
  void _openRecord(RssReadRecordRow record) {
    Navigator.of(context).pop(); // 对标原版点击后 dismiss
    final link = record.link ?? '';
    final hasLink = hasRssArticleLink(link);
    final rssState = ref.read(rssNotifierProvider);
    final selected = rssState.selectedSource;
    String sourceName = record.origin;
    if (selected != null && selected.sourceUrl == record.origin) {
      sourceName = selected.sourceName;
    } else {
      for (final source in rssState.sources) {
        if (source.sourceUrl == record.origin) {
          sourceName = source.sourceName;
          break;
        }
      }
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RssArticleDetailScreen(
          article: RssFeedArticle(
            title: record.title,
            url: hasLink ? link : '',
          ),
          sourceName: sourceName,
          // 无链接（空串/legacy 伪主键）不传 origin，避免空 link 抓正文
          sourceUrl: hasLink ? record.origin : '',
        ),
      ),
    );
  }
}
