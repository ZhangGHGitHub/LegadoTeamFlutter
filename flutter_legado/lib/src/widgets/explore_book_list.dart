/// 发现分类书籍列表组件（ExploreBookList）
///
/// iOS inset 列表：系统灰阶、hairline 分隔、中性交互色。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/explore/explore_show_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../utils/source_login_entry.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/list_footer.dart';
import '../widgets/loading_indicator.dart';

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
            Icon(Icons.lock_outline_rounded, size: 44, color: colorScheme.tertiary),
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
      final err = state.error!;
      // 登录错误（Rust LoginRequired）→ 提供「去登录」引导 — 发现页修复 R4
      if (err.startsWith('LOGIN_REQUIRED:')) {
        return _LoginRequiredView(
          message: err.replaceFirst('LOGIN_REQUIRED:', ''),
          source: state.source,
          onRetry: () =>
              ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
        );
      }
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

class _BookItem extends ConsumerWidget {
  final SearchBook book;
  final VoidCallback onTap;

  const _BookItem({super.key, required this.book, required this.onTap});

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
                width: 45,
                height: 60,
                sourceOrigin: book.origin,
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
                            Icons.check_circle,
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
