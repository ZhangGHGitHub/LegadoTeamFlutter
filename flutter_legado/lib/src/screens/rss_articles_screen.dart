import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/rss/rss_notifier.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_article_detail_screen.dart';

/// RSS 文章列表页面
class RssArticlesScreen extends ConsumerStatefulWidget {
  final RssSource source;

  const RssArticlesScreen({super.key, required this.source});

  @override
  ConsumerState<RssArticlesScreen> createState() => _RssArticlesScreenState();
}

class _RssArticlesScreenState extends ConsumerState<RssArticlesScreen> {
  final Set<String> _readArticles = {};

  @override
  void initState() {
    super.initState();
    // 加载文章
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssNotifierProvider.notifier).selectSource(widget.source);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssNotifierProvider);
    final notifier = ref.read(rssNotifierProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source.sourceName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            notifier.clearSelectedSource();
            Navigator.pop(context);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => notifier.refreshArticles(),
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
              onRetry: () => notifier.selectSource(widget.source),
            );
          }

          if (state.articles.isEmpty) {
            return const EmptyState(
              icon: Icons.article_outlined,
              title: '暂无文章',
              subtitle: '下拉刷新获取最新内容',
            );
          }

          return RefreshIndicator(
            onRefresh: () => notifier.refreshArticles(),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: state.articles.length,
              separatorBuilder: (c, i) =>
                  const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, index) {
                final article = state.articles[index];
                final isRead = _readArticles.contains(article.url);
                return _buildArticleItem(context, article, isRead);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildArticleItem(
      BuildContext context, RssFeedArticle article, bool isRead) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 稳定 ValueKey（文章 url）+ RepaintBoundary 隔离列表项重绘区域
    final item = InkWell(
      key: ValueKey(article.url),
      onTap: () {
        setState(() => _readArticles.add(article.url));
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RssArticleDetailScreen(
              article: article,
              sourceName: widget.source.sourceName,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
            if (article.imageUrl != null && article.imageUrl!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
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
                      borderRadius: BorderRadius.circular(8),
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
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.image_not_supported,
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
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.article,
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
                  if (article.description != null &&
                      article.description!.isNotEmpty)
                    Text(
                      article.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.schedule,
                          size: 12, color: colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        article.pubDate ?? '',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (isRead) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.check_circle_outline,
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
}
