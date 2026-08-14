/// 发现分类书籍列表组件（ExploreBookList）
///
/// iOS inset 列表：系统灰阶、hairline 分隔、中性交互色。
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
class ExploreBookList extends ConsumerStatefulWidget {
  final ExploreShowArgs args;
  final EdgeInsets padding;

  const ExploreBookList({
    super.key,
    required this.args,
    this.padding = EdgeInsets.zero,
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
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

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
      _scrollController.jumpTo(_scrollController.offset + added * 76.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    final state = ref.watch(exploreShowNotifierProvider(args));
    final colorScheme = Theme.of(context).colorScheme;

    if (state.isLoading && state.books.isEmpty) {
      return const LoadingIndicator();
    }

    if (state.error != null && state.books.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () =>
            ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
      );
    }

    if (state.books.isEmpty) {
      return const EmptyState(
        icon: Icons.explore_outlined,
        title: '暂无书籍',
        subtitle: '该分类下没有找到书籍',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TopNetworkLoadingBar(isLoading: state.isLoading && state.books.isNotEmpty),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
            child: ListView.separated(
              controller: _scrollController,
              padding: widget.padding,
              itemCount: state.books.length + 2,
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
                  return _buildLoadPreviousIndicator(state, colorScheme);
                }
                if (index == state.books.length + 1) {
                  return _buildLoadMoreIndicator(args, state, colorScheme);
                }

                final book = state.books[index - 1];
                final dedupeKey =
                    exploreBookDedupeKey(book, listIndex: index - 1);
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

  Widget _buildLoadPreviousIndicator(
    ExploreShowState state,
    ColorScheme colorScheme,
  ) {
    if (state.displayPage <= 1) {
      return const SizedBox(height: 8);
    }
    if (state.isLoading && state.books.isNotEmpty) {
      return Padding(
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Text(
          '上滑加载上一页',
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

class _BookItem extends StatelessWidget {
  final SearchBook book;
  final VoidCallback onTap;

  const _BookItem({super.key, required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
                width: 45,
                height: 60,
                sourceOrigin: book.origin,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.name,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
