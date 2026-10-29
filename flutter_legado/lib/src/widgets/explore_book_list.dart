/// 发现分类书籍列表组件（ExploreBookList）
///
/// iOS inset 列表：系统灰阶、hairline 分隔、中性交互色。
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/explore/explore_show_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../routes.dart';
import '../services/cover_aspect_ratio.dart';
import '../utils/source_login_entry.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/list_footer.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/skeleton.dart';

/// 登录引导错误视图（书源需登录时展示，提供「去登录」主按钮与重试）
///
/// apple-ui-designer：系统灰阶卡片、明确的主次按钮层级、克制的错误文案。
/// — DeepSeek Harness + UI（2026-08-14 发现页修复 R4）
class _LoginRequiredView extends ConsumerWidget {
  final String message;
  final BookSource? source;
  final VoidCallback onRetry;

  const _LoginRequiredView({
    required this.message,
    required this.source,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.lock_outline_rounded, size: 44, color: colorScheme.tertiary),
            const SizedBox(height: 12),
            Text(
              '书源需要登录',
              style: textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              message.isNotEmpty ? message : '登录后即可浏览该分类内容',
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('重试'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: source == null
                      ? null
                      : () async {
                          final ok =
                              await showSourceLogin(context, ref, source!);
                          if (ok && context.mounted) {
                            onRetry();
                          }
                        },
                  child: const Text('去登录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 发现分类书籍列表（自管理滚动分页）
class ExploreBookList extends ConsumerStatefulWidget {
  final ExploreShowArgs args;
  final EdgeInsets padding;

  /// [A1 对齐 | Qoder UI] 本地关键字筛选（匹配书名/作者，忽略大小写；空=不过滤）
  final String filterKeyword;

  /// [A1 对齐 | Qoder UI] 紧凑密度（参考版 ☰ 列表切换语义；false=舒适）
  final bool compact;

  /// 网格列数（null = 列表形态；对齐参考版 layoutState/gridCount）
  ///
  /// 发现页「源内容模式」的书源选择 sheet 可切换列表/网格与列数，
  /// 该参数由调用方传入；独立发现书单页保持既有的列表/紧凑形态。
  final int? gridCount;

  const ExploreBookList({
    super.key,
    required this.args,
    this.padding = EdgeInsets.zero,
    this.filterKeyword = '',
    this.compact = false,
    this.gridCount,
  });

  @override
  ConsumerState<ExploreBookList> createState() => _ExploreBookListState();
}

class _ExploreBookListState extends ConsumerState<ExploreBookList> {
  final _scrollController = ScrollController();

  /// 顶部下拉累计过冲量（达到阈值触发加载上一页）
  double _topOverscroll = 0;

  /// 触发加载上一页的过冲阈值（逻辑像素）：避免轻触/回弹误触
  static const double _previousPageOverscrollTrigger = 24;

  /// 网格行高（封面 + 文本，最近一次布局推导）；用于上一页滚动补偿
  double _gridRowExtent = 0;

  /// 书籍卡片渲染键（去重键 → GlobalKey）：顶部下拉加载上一页后按
  /// 「首可见项 + 相对偏移」恢复滚动位置（对齐原版 upData 的
  /// firstVisibleItemPosition/offset 锚点）
  final Map<String, GlobalKey> _itemKeys = {};

  /// 渲染键缓存上限（超出后清空重建，避免长列表无限增长）
  static const int _itemKeyCacheLimit = 600;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 封面比例设置/新解析比例 → 网格行高重算
    uiSettingsListenable.addListener(_onCoverLayoutChanged);
    coverAspectRatioRevision.addListener(_onCoverLayoutChanged);
  }

  @override
  void dispose() {
    uiSettingsListenable.removeListener(_onCoverLayoutChanged);
    coverAspectRatioRevision.removeListener(_onCoverLayoutChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onCoverLayoutChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      ref.read(exploreShowNotifierProvider(widget.args).notifier).loadMore();
    }
  }

  /// 滚动通知：在列表顶部继续下拉（overscroll）后松手加载上一页
  ///
  /// 对齐原版 RecyclerView `!canScrollVertically(-1) && dy < 0` 的触发语义，
  /// 但把触发点定在 [ScrollEndNotification]（松手/回弹后）：若在拖动中段就
  /// 改写列表并跳转锚点，会和用户仍在进行的手势抢滚动位置。
  /// page = 1（[ExploreShowState.displayPage] <= 1）时不触发，下拉刷新保持原行为。
  bool _onScrollNotification(ScrollNotification notification) {
    // 只处理列表自身的滚动（忽略嵌套滚动如横向标签条）
    if (notification.depth != 0) return false;
    if (notification is ScrollEndNotification) {
      final pulled = _topOverscroll;
      _topOverscroll = 0;
      if (pulled >= _previousPageOverscrollTrigger) {
        _tryLoadPreviousPage();
      }
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.metrics.extentBefore > 0) {
      _topOverscroll = 0;
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.overscroll < 0 &&
        notification.metrics.extentBefore <= 0) {
      _topOverscroll += -notification.overscroll;
    }
    return false;
  }

  /// 触发加载上一页（失败时由顶部条内联重试）
  ///
  /// 加载前记录锚点（首可见书 + 相对偏移），完成后先按估值补偿让锚点项
  /// 进入构建范围，再在下一帧按真实布局校正，保证视觉位置不跳。
  Future<void> _tryLoadPreviousPage() async {
    final state = ref.read(exploreShowNotifierProvider(widget.args));
    if (state.displayPage <= 1 ||
        state.isLoading ||
        state.isLoadingPrevious) {
      return;
    }
    final anchor = _captureAnchor();
    final countBefore = state.books.length;
    await ref
        .read(exploreShowNotifierProvider(widget.args).notifier)
        .loadPreviousPage();
    if (!mounted) return;
    final next = ref.read(exploreShowNotifierProvider(widget.args));
    if (next.books.length <= countBefore) return; // 失败或整页重复：保持原位
    if (anchor != null) {
      await _restoreAnchor(anchor, next.books.length - countBefore);
    }
  }

  /// 顶部条点击重试（失败态）
  Future<void> _retryPreviousPage() async {
    final state = ref.read(exploreShowNotifierProvider(widget.args));
    if (state.isLoadingPrevious || state.isLoading) return;
    final anchor = _captureAnchor();
    final countBefore = state.books.length;
    await ref
        .read(exploreShowNotifierProvider(widget.args).notifier)
        .retryPreviousPage();
    if (!mounted) return;
    final next = ref.read(exploreShowNotifierProvider(widget.args));
    if (next.books.length <= countBefore) return;
    if (anchor != null) {
      await _restoreAnchor(anchor, next.books.length - countBefore);
    }
  }

  /// 记录当前首个可见书籍卡片的去重键与相对偏移
  _PreviousPageAnchor? _captureAnchor() {
    final ancestor = context.findRenderObject();
    if (ancestor is! RenderBox || !ancestor.hasSize) return null;
    _PreviousPageAnchor? best;
    for (final entry in _itemKeys.entries) {
      final itemContext = entry.value.currentContext;
      if (itemContext == null) continue;
      final box = itemContext.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero, ancestor: ancestor).dy;
      // 完全滚出视口上方的不作为锚点
      if (dy + box.size.height <= 0) continue;
      if (best == null || dy < best.dy) {
        best = _PreviousPageAnchor(bookKey: entry.key, dy: dy);
      }
    }
    return best;
  }

  /// 恢复锚点：先按新增条目估值补偿，再在下一帧按真实布局校正
  Future<void> _restoreAnchor(_PreviousPageAnchor anchor, int addedCount) async {
    if (!_scrollController.hasClients || addedCount <= 0) return;
    final position = _scrollController.position;
    final approx = explorePreviousPageShift(
      addedCount: addedCount,
      gridCount: widget.gridCount,
      gridRowExtent: _gridRowExtent,
    );
    if (approx > 0) {
      _scrollController.jumpTo(
        (position.pixels + approx)
            .clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
    // 等新布局完成后再按锚点真实位置校正（估值与真实行高有偏差）
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _correctAnchor(anchor);
  }

  /// 按锚点项当前真实位置与触发时偏移的差值精确校正滚动位置
  void _correctAnchor(_PreviousPageAnchor anchor) {
    if (!_scrollController.hasClients) return;
    final itemContext = _itemKeys[anchor.bookKey]?.currentContext;
    final ancestor = context.findRenderObject();
    if (itemContext == null || ancestor is! RenderBox) return;
    final box = itemContext.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final dy = box.localToGlobal(Offset.zero, ancestor: ancestor).dy;
    final delta = dy - anchor.dy;
    if (delta.abs() < 0.5) return;
    final position = _scrollController.position;
    _scrollController.jumpTo(
      (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  /// 取（或创建）书籍卡片渲染键
  Key _itemKey(String dedupeKey) {
    if (_itemKeys.length >= _itemKeyCacheLimit) _itemKeys.clear();
    return _itemKeys.putIfAbsent(dedupeKey, GlobalKey.new);
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    final state = ref.watch(exploreShowNotifierProvider(args));
    final colorScheme = Theme.of(context).colorScheme;

    if (state.isLoading && state.books.isEmpty) {
      // [LAYOUT_PLAN P4 收尾] 首屏 Skeleton 接线：列表骨架替代整页 LoadingIndicator
      return ListView.builder(
        padding: widget.padding,
        itemCount: 8,
        itemBuilder: (_, _) => const ListSkeletonItem(),
      );
    }

    if (state.error != null && state.books.isEmpty) {
      final err = state.error!;
      // 登录错误（Rust LoginRequired）→ 提供「去登录」引导 — 发现页修复 R4
      if (err.startsWith('LOGIN_REQUIRED:')) {
        return _LoginRequiredView(
          message: err.replaceFirst('LOGIN_REQUIRED:', ''),
          source: state.source,
          onRetry: () =>
              ref.read(exploreShowNotifierProvider(args).notifier).retry(),
        );
      }
      return ErrorView(
        message: state.error!,
        onRetry: () =>
            ref.read(exploreShowNotifierProvider(args).notifier).retry(),
      );
    }

    if (state.books.isEmpty) {
      return const EmptyState(
        icon: Symbols.explore_rounded,
        title: '暂无书籍',
        subtitle: '该分类下没有找到书籍',
      );
    }

    // [A1 对齐 | Qoder UI] 关键字筛选（匹配书名/作者，忽略大小写）
    final keyword = widget.filterKeyword.trim().toLowerCase();
    final visibleBooks = keyword.isEmpty
        ? state.books
        : state.books
            .where(
              (b) =>
                  b.name.toLowerCase().contains(keyword) ||
                  b.author.toLowerCase().contains(keyword),
            )
            .toList();
    if (visibleBooks.isEmpty) {
      return EmptyState(
        icon: Symbols.filter_alt_rounded,
        title: '筛选后无匹配书籍',
        subtitle: '已加载的书籍中没有匹配「${widget.filterKeyword}」',
      );
    }

    // 网格形态（发现页源内容模式的布局列数，对齐参考版 layoutState=1）
    final columns = widget.gridCount;
    if (columns != null && columns >= 1) {
      return _buildGridBody(args, state, visibleBooks, columns, colorScheme);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TopNetworkLoadingBar(isLoading: state.isLoading && state.books.isNotEmpty),
        Expanded(
          // 顶部下拉手势：page > 1 时加载上一页；page = 1 时保留下拉刷新
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: CustomRefreshIndicator(
              // 与加载上一页互斥：顶栏有上一页可用时，顶部下拉归「加载上一页」
              enabled: state.displayPage <= 1,
              onRefresh: () =>
                  ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
              child: ListView.separated(
                controller: _scrollController,
                // 内容不足一屏时也允许下拉（刷新/加载上一页手势）
                physics: const AlwaysScrollableScrollPhysics(),
                padding: widget.padding,
                itemCount: visibleBooks.length + 2,
                separatorBuilder: (context, index) {
                  if (index == 0 || index >= state.books.length) {
                    return const SizedBox.shrink();
                  }
                  return Divider(
                    height: 1,
                    indent: 73,
                    color: colorScheme.outlineVariant.withValues(alpha: 0.55),
                  );
                },
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _buildLoadPreviousIndicator(
                      state,
                      colorScheme,
                      onRetry: _retryPreviousPage,
                    );
                  }
                  if (index == visibleBooks.length + 1) {
                    return _buildLoadMoreIndicator(args, state, colorScheme);
                  }

                  final book = visibleBooks[index - 1];
                  final dedupeKey =
                      exploreBookDedupeKey(book, listIndex: index - 1);
                  return RepaintBoundary(
                    key: _itemKey(dedupeKey),
                    child: _BookItem(
                      book: book,
                      compact: widget.compact,
                      onTap: () => _showBookInfo(book),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 网格形态列表（对齐参考版 LazyVerticalGrid：固定列数 + 上滑加载更多 +
  /// 顶部条（page > 1 时下拉加载上一页）；下拉刷新/错误重试链路与列表形态一致）
  Widget _buildGridBody(
    ExploreShowArgs args,
    ExploreShowState state,
    List<SearchBook> visibleBooks,
    int columns,
    ColorScheme colorScheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TopNetworkLoadingBar(
          isLoading: state.isLoading && state.books.isNotEmpty,
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: CustomRefreshIndicator(
              // 与加载上一页互斥（同列表形态）
              enabled: state.displayPage <= 1,
              onRefresh: () =>
                  ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
              // 按可用宽度推导网格单元尺寸：封面保持 3:4 等比，
              // 文本区高度随字体缩放自适应（避免固定 childAspectRatio 在
              // 大列数/大字号下压扁封面或溢出）
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = columns.clamp(1, 10);
                  const crossSpacing = 8.0;
                  const mainSpacing = 12.0;
                  // 网格自带水平页边距（列表形态的行内边距在行组件内部）
                  final horizontalPadding = widget.padding.horizontal > 0
                      ? widget.padding.horizontal
                      : 16.0;
                  final contentWidth =
                      constraints.maxWidth - horizontalPadding * 2;
                  final itemWidth = contentWidth > 0
                      ? (contentWidth -
                                crossSpacing * (crossAxisCount - 1)) /
                            crossAxisCount
                      : 0.0;
                  final textScaler = MediaQuery.textScalerOf(context);
                  final textBlockHeight = textScaler.scale(14) * 1.25 * 2 + 6;
                  // [批39] 网格行高随封面比例：限制比例开 = 既有 3:4 基准；
                  // 关 = 按已解析的原图比例（整格统一，取首个已知比例）
                  final restrictRatio =
                      uiSettingsListenable.value.restrictCoverRatio;
                  final coverRatio = restrictRatio
                      ? 3 / 4
                      : CoverAspectRatio.representativeRatio(
                          visibleBooks.map((b) => b.coverUrl),
                        );
                  final rowExtent = itemWidth > 0
                      ? itemWidth / coverRatio + textBlockHeight + 6
                      : 120.0;
                  _gridRowExtent = rowExtent;

                  return CustomScrollView(
                    controller: _scrollController,
                    // 内容不足一屏时也允许下拉（刷新/加载上一页手势）
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: SizedBox(height: widget.padding.top),
                      ),
                      if (state.displayPage > 1)
                        SliverToBoxAdapter(
                          child: _buildLoadPreviousIndicator(
                            state,
                            colorScheme,
                            onRetry: _retryPreviousPage,
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontalPadding,
                        ),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                crossAxisSpacing: crossSpacing,
                                mainAxisSpacing: mainSpacing,
                                mainAxisExtent: rowExtent,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final book = visibleBooks[index];
                              final dedupeKey = exploreBookDedupeKey(
                                book,
                                listIndex: index,
                              );
                              return RepaintBoundary(
                                key: _itemKey(dedupeKey),
                                child: _BookGridItem(
                                  book: book,
                                  onTap: () => _showBookInfo(book),
                                ),
                              );
                            },
                            childCount: visibleBooks.length,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _buildLoadMoreIndicator(
                          args,
                          state,
                          colorScheme,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: widget.padding.bottom),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部「加载上一页」条（page > 1 才显示）
  ///
  /// - 加载中：转圈（对齐原版顶部 LoadMoreView.startLoad）
  /// - 失败：内联错误 + 点击重试（对齐原版 errorTopLiveData → loadMoreViewTop.error）
  /// - 就绪：下拉提示（原版该条无文字，仅作为顶部手势入口的视觉提示）
  Widget _buildLoadPreviousIndicator(
    ExploreShowState state,
    ColorScheme colorScheme, {
    required Future<void> Function() onRetry,
  }) {
    if (state.displayPage <= 1) {
      return const SizedBox(height: 8);
    }
    if (state.isLoadingPrevious) {
      return Padding(
        key: const ValueKey('explore-load-previous-loading'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    if (state.previousError != null) {
      return Padding(
        key: const ValueKey('explore-load-previous-error'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: colorScheme.onSurface),
            onPressed: onRetry,
            child: const Text('上一页加载失败，点击重试'),
          ),
        ),
      );
    }
    return Padding(
      key: const ValueKey('explore-load-previous-hint'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Text(
          '下拉加载上一页',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildLoadMoreIndicator(
    ExploreShowArgs args,
    ExploreShowState state,
    ColorScheme colorScheme,
  ) {
    if (state.isLoading) {
      return const ListLoadMoreFooter();
    }
    if (!state.hasMore) {
      return const ListBottomLineFooter();
    }
    if (state.error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: colorScheme.onSurface,
            ),
            onPressed: () => ref
                .read(exploreShowNotifierProvider(args).notifier)
                .loadMore(),
            child: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    return const SizedBox(height: 16);
  }

  void _showBookInfo(SearchBook book) {
    final bookObj = Book(
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      kind: book.kind,
      coverUrl: book.coverUrl,
      intro: book.intro,
      bookType: book.bookType,
      latestChapterTitle: book.latestChapterTitle,
      wordCount: book.wordCount,
    );
    Navigator.pushNamed(context, AppRoutes.bookInfo, arguments: bookObj);
  }
}

/// 加载上一页前的滚动锚点（对齐原版 upData：
/// `findFirstVisibleItemPosition` + `findViewByPosition(...).top`）
class _PreviousPageAnchor {
  const _PreviousPageAnchor({required this.bookKey, required this.dy});

  /// 首可见书籍卡片的去重键（[exploreBookDedupeKey]）
  final String bookKey;

  /// 锚点卡片顶边相对列表区域的像素偏移（触发加载时的值）
  final double dy;
}

/// 加载上一页后的滚动补偿距离
///
/// 列表形态沿用既有估值（单行 76dp）；网格按「新增行数 ×（行高 + 行间距）」
/// 补偿，避免用列表行高导致视口跳到半行位置。
double explorePreviousPageShift({
  required int addedCount,
  int? gridCount,
  double gridRowExtent = 0,
}) {
  if (addedCount <= 0) return 0;
  if (gridCount != null && gridCount >= 1 && gridRowExtent > 0) {
    final rows = (addedCount / gridCount.clamp(1, 10)).ceil();
    return rows * (gridRowExtent + 12);
  }
  return addedCount * 76.0;
}

class _BookItem extends ConsumerWidget {
  final SearchBook book;
  final VoidCallback onTap;

  /// [A1 对齐 | Qoder UI] 紧凑密度：封面缩小 + 简介单行
  final bool compact;

  const _BookItem({
    required this.book,
    required this.onTap,
    this.compact = false,
  });

  /// 是否已在书架（对齐原版 ExploreShowViewModel.isInBookShelf 三元匹配：
  /// 「名-作者」/「名」（作者空退化）/「bookUrl」）— 发现页修复 R5
  bool _isInShelf(List<Book> shelfBooks) {
    final name = book.name.trim();
    final author = book.author.trim();
    if (name.isEmpty && book.bookUrl.isEmpty) return false;
    return shelfBooks.any((b) {
      if (b.bookUrl == book.bookUrl) return true;
      final bn = b.name.trim();
      final ba = b.author.trim();
      if (author.isNotEmpty && ba.isNotEmpty) {
        return '$bn-$ba' == '$name-$author';
      }
      return author.isEmpty && ba.isEmpty && bn == name;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final inShelf = ref.watch(
      bookshelfNotifierProvider.select((s) => _isInShelf(s.books)),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BookCover(
                coverUrl: book.coverUrl,
                width: compact ? 36 : 45,
                height: compact ? 48 : 60,
                sourceOrigin: book.origin,
                // [批39] 跟随「限制封面比例」：关闭时按原图比例自适应高度
                adaptAspectRatio: true,
                adaptiveMinHeight: compact ? 36 : 45,
                adaptiveMaxHeight: compact ? 84 : 105,
                // [LAYOUT_MOTION_AUDIT M1] 发现结果封面补 Hero（进详情过渡）
                heroTag: 'book-cover:${book.bookUrl}',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            book.name,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                              height: 1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 在架标记（对齐原版 ivInBookshelf；轻量系统灰阶角标）— R5
                        if (inShelf) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Symbols.check_circle_rounded,
                            size: 15,
                            color: colorScheme.tertiary,
                          ),
                        ],
                      ],
                    ),
                    if (book.author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        book.author,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (book.latestChapterTitle != null &&
                        book.latestChapterTitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        book.latestChapterTitle!,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.85),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (book.intro != null && book.intro!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        book.intro!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.65),
                        ),
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    // 分类标签（对齐原版 ExploreShowAdapter llKind；轻量灰阶 chip）— R5
                    if (book.kind != null && book.kind!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          for (final k in book.kind!
                              .split(',')
                              .map((e) => e.trim())
                              .where((e) => e.isNotEmpty)
                              .take(4))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                k,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 发现书籍网格卡（书封 + 书名 + 作者；对齐参考版 ExploreBookGridItem 形态）
class _BookGridItem extends StatelessWidget {
  final SearchBook book;
  final VoidCallback onTap;

  const _BookGridItem({
    required this.book,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => BookCover(
                coverUrl: book.coverUrl,
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                sourceOrigin: book.origin,
                heroTag: 'book-cover:${book.bookUrl}',
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
          if (book.author.isNotEmpty)
            Text(
              book.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
