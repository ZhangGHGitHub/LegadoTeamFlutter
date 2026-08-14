/// 发现分类书籍列表组件（ExploreBookList）
///
/// 抽取自 ExploreShowScreen，供全屏浏览页与平板双栏右栏复用。
/// 核心功能：
/// 1. 书籍列表（封面+书名+作者+最新章节，对标 Android ExploreShowAdapter）
/// 2. 支持下拉刷新 + 上滑触底翻页加载
/// 3. 点击书籍跳转书籍详情页
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/explore/explore_show_notifier.dart';
import '../routes.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/list_footer.dart';
import '../widgets/loading_indicator.dart';

/// 发现分类书籍列表（自管理滚动分页）
///
/// 以 [ExploreShowArgs] 命中对应的 [exploreShowNotifierProvider]（family + autoDispose），
/// 渲染该分类下的书籍列表并处理触底加载。可独立嵌入任意父容器（全屏页 / 平板右栏）。
class ExploreBookList extends ConsumerStatefulWidget {
  /// 分类参数（书源 + 分类名 + 分类 URL）
  final ExploreShowArgs args;

  /// 列表内边距（全屏页与双栏右栏可定制）
  final EdgeInsets padding;

  const ExploreBookList({
    super.key,
    required this.args,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  @override
  ConsumerState<ExploreBookList> createState() => _ExploreBookListState();
}

class _ExploreBookListState extends ConsumerState<ExploreBookList> {
  final _scrollController = ScrollController();
  bool _loadingPrevious = false;

  @override
  void initState() {
    super.initState();
    // 监听滚动：触底加载下一页、到顶加载上一页（对标 Android scrollToBottom/scrollToTop）
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：触底加载更多、到顶加载上一页
  void _onScroll() {
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      ref.read(exploreShowNotifierProvider(widget.args).notifier).loadMore();
    } else if (position.pixels <= position.minScrollExtent + 40 &&
        position.userScrollDirection == ScrollDirection.reverse) {
      _tryLoadPreviousPage();
    }
  }

  Future<void> _tryLoadPreviousPage() async {
    final state = ref.read(exploreShowNotifierProvider(widget.args));
    if (_loadingPrevious || state.isLoading || state.displayPage <= 1) return;
    _loadingPrevious = true;
    final prevCount = state.books.length;
    await ref
        .read(exploreShowNotifierProvider(widget.args).notifier)
        .loadPreviousPage();
    if (!mounted) return;
    _loadingPrevious = false;
    final newCount =
        ref.read(exploreShowNotifierProvider(widget.args)).books.length;
    final added = newCount - prevCount;
    if (added > 0 && _scrollController.hasClients) {
      // 保持视口位置（对标 Android scrollToPositionWithOffset）
      _scrollController.jumpTo(_scrollController.offset + added * 72.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    // family + autoDispose：相同 args 命中同一 Notifier，组件销毁自动释放
    final state = ref.watch(exploreShowNotifierProvider(args));

    // 首次加载且无数据时显示 loading
    if (state.isLoading && state.books.isEmpty) {
      return const LoadingIndicator();
    }

    // 错误且无数据
    if (state.error != null && state.books.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () =>
            ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
      );
    }

    // 空列表
    if (state.books.isEmpty) {
      return const EmptyState(
        icon: Icons.explore_outlined,
        title: '暂无书籍',
        subtitle: '该分类下没有找到书籍',
      );
    }

    // 书籍列表（支持下拉刷新 + 顶栏加载条）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TopNetworkLoadingBar(isLoading: state.isLoading && state.books.isNotEmpty),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
            child: ListView.builder(
              controller: _scrollController,
              padding: widget.padding,
              // +2：顶/底部分页指示
              itemCount: state.books.length + 2,
              itemBuilder: (context, index) {
                // 顶部分页指示（上一页）
                if (index == 0) {
                  return _buildLoadPreviousIndicator(state);
                }

                // 底部分页指示（下一页）
                if (index == state.books.length + 1) {
                  return _buildLoadMoreIndicator(args, state);
                }

                final book = state.books[index - 1];
                final dedupeKey =
                    exploreBookDedupeKey(book, listIndex: index - 1);
                // 稳定 ValueKey + RepaintBoundary 隔离列表项重绘区域
                return RepaintBoundary(
                  child: _BookItem(
                    key: ValueKey(dedupeKey),
                    book: book,
                    onTap: () => _showBookInfo(book),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部分页指示（对标 Android loadMoreViewTop）
  Widget _buildLoadPreviousIndicator(ExploreShowState state) {
    if (state.displayPage <= 1) {
      return const SizedBox(height: 8);
    }
    if (state.isLoading && state.books.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          '上滑加载上一页',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  /// 底部加载指示器（对标 Android LoadMoreView）
  Widget _buildLoadMoreIndicator(ExploreShowArgs args, ExploreShowState state) {
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
            onPressed: () =>
                ref.read(exploreShowNotifierProvider(args).notifier).loadMore(),
            child: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }

    return const SizedBox(height: 16);
  }

  /// 跳转书籍详情页（对标 Android showBookInfo → BookInfoActivity）
  void _showBookInfo(SearchBook book) {
    // 构造 Book 对象用于跳转
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

/// 书籍列表项（对标 Android ExploreShowAdapter item 布局）
class _BookItem extends StatelessWidget {
  final SearchBook book;
  final VoidCallback onTap;

  const _BookItem({super.key, required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面（对标 Android iv_cover: 45x60dp）
            BookCover(
              coverUrl: book.coverUrl,
              width: 45,
              height: 60,
              sourceOrigin: book.origin,
            ),
            const SizedBox(width: 12),
            // 书籍信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 书名（对标 Android tv_name: 16sp primaryText）
                  Text(
                    book.name,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // 作者（对标 Android tv_author: 12sp secondaryText）
                  if (book.author.isNotEmpty)
                    Text(
                      book.author,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  // 最新章节（对标 Android tv_last: 12sp secondaryText）
                  if (book.latestChapterTitle != null &&
                      book.latestChapterTitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '最新：${book.latestChapterTitle}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  // 简介（可选显示）
                  if (book.intro != null && book.intro!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      book.intro!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // 右侧箭头
            Icon(
              Icons.chevron_right,
              size: 20,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}
