/// 发现分类书籍浏览页面（ExploreShowScreen）
///
/// 参考 Android 原版 ExploreShowActivity.kt 实现
/// 核心功能：
/// 1. 顶栏显示"分类名 - 书源名"
/// 2. 书籍列表（封面+书名+作者+最新章节）
/// 3. 支持下拉刷新 + 上滑翻页加载
/// 4. 点击书籍跳转书籍详情页
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/explore/explore_show_notifier.dart';
import '../routes.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

// 重新导出路由参数，供 routes.dart 通过本文件引用 ExploreShowArgs
export '../providers/explore/explore_show_notifier.dart' show ExploreShowArgs;

/// 发现分类书籍浏览页
class ExploreShowScreen extends ConsumerStatefulWidget {
  /// 路由参数（通过 Navigator.pushNamed 传入）
  final ExploreShowArgs? args;

  const ExploreShowScreen({super.key, this.args});

  @override
  ConsumerState<ExploreShowScreen> createState() => _ExploreShowScreenState();
}

class _ExploreShowScreenState extends ConsumerState<ExploreShowScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 监听滚动，触底加载更多
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：触底加载更多（对标 Android scrollToBottom）
  void _onScroll() {
    final args = widget.args;
    if (args == null) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(exploreShowNotifierProvider(args).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    // 参数缺失兜底（正常路径由 routes.dart 保证非空）
    if (args == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('')),
        body: const EmptyState(
          icon: Icons.explore_outlined,
          title: '参数错误',
          subtitle: '缺少发现分类参数',
        ),
      );
    }

    // family + autoDispose：相同 args 命中同一 Notifier，页面销毁自动释放
    final state = ref.watch(exploreShowNotifierProvider(args));

    return Scaffold(
      appBar: AppBar(
        // 对标 Android: binding.titleBar.title = intent.getStringExtra("exploreName")
        title: Text(state.title),
      ),
      body: _buildBody(args, state),
    );
  }

  Widget _buildBody(ExploreShowArgs args, ExploreShowState state) {
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

    // 书籍列表（支持下拉刷新）
    return RefreshIndicator(
      onRefresh: () =>
          ref.read(exploreShowNotifierProvider(args).notifier).refresh(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        // +1 用于底部加载指示器
        itemCount: state.books.length + 1,
        itemBuilder: (context, index) {
          // 底部加载指示器
          if (index == state.books.length) {
            return _buildLoadMoreIndicator(args, state);
          }

          final book = state.books[index];
          // 稳定 ValueKey（bookUrl）+ RepaintBoundary 隔离列表项重绘区域
          return RepaintBoundary(
            child: _BookItem(
              key: ValueKey(book.bookUrl),
              book: book,
              onTap: () => _showBookInfo(book),
            ),
          );
        },
      ),
    );
  }

  /// 底部加载指示器（对标 Android LoadMoreView）
  Widget _buildLoadMoreIndicator(ExploreShowArgs args, ExploreShowState state) {
    if (state.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (!state.hasMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            '没有更多了',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
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
            BookCover(coverUrl: book.coverUrl, width: 45, height: 60),
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
