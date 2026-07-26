import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/rust_api.dart';

/// RSS 文章详情页面
class RssArticleDetailScreen extends StatelessWidget {
  final RssFeedArticle article;
  final String sourceName;

  const RssArticleDetailScreen({
    super.key,
    required this.article,
    this.sourceName = '',
  });

  Future<void> _openInBrowser() async {
    final uri = Uri.tryParse(article.url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('文章详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: '在浏览器中打开',
            onPressed: _openInBrowser,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: '分享',
            onPressed: () async {
              final uri = Uri.tryParse(article.url);
              if (uri != null && await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            Text(
              article.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            // 元信息：日期 + 来源
            Row(
              children: [
                if (article.pubDate != null && article.pubDate!.isNotEmpty) ...[
                  Icon(Icons.schedule,
                      size: 14, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      article.pubDate!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                if (sourceName.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Icon(Icons.rss_feed,
                      size: 14, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      sourceName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            // 封面图
            if (article.imageUrl != null && article.imageUrl!.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  article.imageUrl!,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, s) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // 文章内容
            if (article.content != null && article.content!.isNotEmpty)
              _buildContent(context, article.content!)
            else if (article.description != null &&
                article.description!.isNotEmpty)
              _buildContent(context, article.description!)
            else
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      Icon(Icons.article_outlined,
                          size: 64,
                          color: colorScheme.onSurfaceVariant.withAlpha(100)),
                      const SizedBox(height: 12),
                      Text(
                        '暂无内容',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _openInBrowser,
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('在浏览器中查看原文'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 24),
            // 原文链接按钮
            if (article.url.isNotEmpty)
              Center(
                child: FilledButton.icon(
                  onPressed: _openInBrowser,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('查看原文链接'),
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// 构建文章内容（纯文本渲染，去除 HTML 标签）
  Widget _buildContent(BuildContext context, String content) {
    final theme = Theme.of(context);
    // 简单的 HTML 标签去除（纯文本展示）
    final plainText = _stripHtmlTags(content);
    return Text(
      plainText,
      style: theme.textTheme.bodyLarge?.copyWith(
        height: 1.8,
        color: theme.colorScheme.onSurface,
      ),
    );
  }

  /// 去除 HTML 标签
  String _stripHtmlTags(String htmlString) {
    final exp = RegExp(r'<[^>]*>', multiLine: true, dotAll: true);
    return htmlString
        .replaceAll(exp, '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
  }
}
