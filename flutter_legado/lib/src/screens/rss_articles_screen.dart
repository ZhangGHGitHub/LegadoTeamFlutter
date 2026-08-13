import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/rss/rss_notifier.dart';
import '../providers/rss_history/rss_history_notifier.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_article_detail_screen.dart';
import 'rss_source_edit_screen.dart';
import 'source_login_screen.dart';

/// RSS 文章列表页面
class RssArticlesScreen extends ConsumerStatefulWidget {
  final RssSource source;

  const RssArticlesScreen({super.key, required this.source});

  @override
  ConsumerState<RssArticlesScreen> createState() => _RssArticlesScreenState();
}

class _RssArticlesScreenState extends ConsumerState<RssArticlesScreen> {
  final Set<String> _readArticles = {};

  // [UI-fix v2.0.2 | 2026-08-06] 布局切换本地态（对标原版 articleStyle 0-4
  // 循环；Flutter 端支持两种渲染：0=列表，其他=双列网格） — Qoder
  late int _articleStyle = widget.source.articleStyle;

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
      appBar: LegadoAppBar(
        title: Text(widget.source.sourceName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
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
          // [UI-fix v2.0.2 | 2026-08-06] 文章列表菜单（对标原版
          // rss_articles.xml：登录/刷新排序/设置源变量/编辑源/切换布局/
          // 阅读记录/清空，不含搜索） — Qoder
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
            child: _articleStyle == 0
                ? ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: state.articles.length,
                    // iOS 风格：分隔线从文字列起始处缩进（16 边距 + 80 缩略图 + 12 间距）
                    separatorBuilder: (c, i) =>
                        const Divider(height: 1, indent: 108, endIndent: 16),
                    itemBuilder: (context, index) {
                      final article = state.articles[index];
                      final isRead = _readArticles.contains(article.url);
                      return _buildArticleItem(context, article, isRead);
                    },
                  )
                // [UI-fix v2.0.2 | 2026-08-06] 布局切换：双列网格渲染 — Qoder
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.72,
                        ),
                    itemCount: state.articles.length,
                    itemBuilder: (context, index) {
                      final article = state.articles[index];
                      final isRead = _readArticles.contains(article.url);
                      return _buildGridItem(context, article, isRead);
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
                  borderRadius: BorderRadius.circular(10),
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

  // ===== [UI-fix v2.0.2 | 2026-08-06] 菜单处理（对标 rss_articles.xml）— Qoder =====

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
        ),
      ),
    );
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
                          Icons.image_not_supported,
                          color: colorScheme.onSurfaceVariant.withAlpha(128),
                        ),
                      ),
                    )
                  : Container(
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.article,
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
        // 对标原版 menu_refresh_sort（清排序缓存后重建）；Flutter 端
        // 无独立排序缓存，映射为重新拉取文章列表
        ref.read(rssNotifierProvider.notifier).refreshArticles();
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
      ref.read(rssHistoryNotifierProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssHistoryNotifierProvider);
    // FFI 无按源查询接口，客户端按 origin 过滤（TODO: 待 getRecordsByOrigin 补齐）
    final records = state.records
        .where((r) => r.origin == widget.origin)
        .toList();
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
}
