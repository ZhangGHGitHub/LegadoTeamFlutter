import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/models.dart';
import '../widgets/open_url_confirm_dialog.dart';

/// RSS 文章详情页面
///
/// 使用 WebView 渲染文章 HTML 内容（支持 JS 执行）。
/// 当 WebView 不可用时（如桌面端），降级为纯文本渲染。
class RssArticleDetailScreen extends StatefulWidget {
  final RssFeedArticle article;
  final String sourceName;

  const RssArticleDetailScreen({
    super.key,
    required this.article,
    this.sourceName = '',
  });

  @override
  State<RssArticleDetailScreen> createState() => _RssArticleDetailScreenState();
}

class _RssArticleDetailScreenState extends State<RssArticleDetailScreen> {
  /// WebView 控制器（仅在支持 WebView 的平台初始化）
  WebViewController? _webViewController;

  /// 标记 WebView 是否加载完成
  bool _isWebLoading = true;

  /// WebView 加载错误信息
  String? _webError;

  /// 当前是否使用 WebView 模式（可切换为纯文本）
  bool _useWebView = true;

  /// 判断当前平台是否支持 WebView
  ///
  /// webview_flutter 目前支持 Android / iOS / macOS，
  /// Windows / Linux 桌面端暂不支持，降级为纯文本渲染。
  bool get _isWebViewSupported {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return true;
    }
    return false;
  }

  /// 获取文章 HTML 内容（优先 content，其次 description）
  String? get _articleHtml {
    if (widget.article.content != null && widget.article.content!.isNotEmpty) {
      return widget.article.content;
    }
    if (widget.article.description != null &&
        widget.article.description!.isNotEmpty) {
      return widget.article.description;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // 仅在支持 WebView 的平台且有内容时初始化控制器
    if (_isWebViewSupported && _articleHtml != null && _useWebView) {
      _initWebView();
    } else {
      _isWebLoading = false;
    }
  }

  /// 初始化 WebView 控制器并加载文章 HTML 内容
  void _initWebView() {
    final html = _articleHtml;
    if (html == null) {
      _isWebLoading = false;
      return;
    }

    _webViewController = WebViewController()
      // 启用 JavaScript 执行（参考 Kotlin 原版 webView.settings.javaScriptEnabled = true）
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 页面开始加载回调
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _isWebLoading = true;
                _webError = null;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) {
              setState(() => _isWebLoading = false);
            }
          },
          onWebResourceError: (error) {
            if (mounted) {
              setState(() {
                _isWebLoading = false;
                _webError = error.description;
              });
            }
          },
          // 拦截外部链接，在系统浏览器中打开
          onNavigationRequest: (request) {
            final articleUrl = widget.article.url;
            // 允许同域导航（文章内链接）
            if (request.url.startsWith(articleUrl) ||
                request.url.startsWith('data:') ||
                request.url.startsWith('about:')) {
              return NavigationDecision.navigate;
            }
            // 外部链接在系统浏览器打开
            _openUrlExternally(request.url);
            return NavigationDecision.prevent;
          },
        ),
      );

    // 构造带样式的 HTML 页面并加载
    final styledHtml = _wrapHtmlWithStyle(html);
    _webViewController!.loadHtmlString(styledHtml);
  }

  /// 为 HTML 内容注入响应式样式
  ///
  /// 参考 Kotlin 原版通过 WebSettings 设置 viewport 和字体大小，
  /// 这里通过 CSS 实现移动端友好的阅读体验。
  String _wrapHtmlWithStyle(String htmlContent) {
    // 如果内容已是完整 HTML 文档，直接注入样式
    if (htmlContent.contains('<html') || htmlContent.contains('<body')) {
      // 在 <head> 中注入 viewport 和样式
      if (htmlContent.contains('<head>')) {
        return htmlContent.replaceFirst('<head>', '<head>$_injectedStyle');
      }
      // 无 <head> 时在 <html> 后注入
      if (htmlContent.contains('<html')) {
        return htmlContent.replaceFirst(
          RegExp(r'<html[^>]*>'),
          '\$0<head>$_injectedStyle</head>',
        );
      }
      return '$_injectedStyle$htmlContent';
    }
    // 非完整文档，包装为完整 HTML
    return '''
<!DOCTYPE html>
<html>
<head>
$_injectedStyle
</head>
<body>
$htmlContent
</body>
</html>
''';
  }

  /// 注入的 CSS 样式（响应式布局、暗色模式支持）
  static const String _injectedStyle = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
<style>
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    font-size: 16px;
    line-height: 1.8;
    padding: 16px;
    margin: 0;
    word-wrap: break-word;
    overflow-wrap: break-word;
  }
  img {
    max-width: 100%;
    height: auto;
    border-radius: 8px;
  }
  pre, code {
    overflow-x: auto;
    white-space: pre-wrap;
    word-wrap: break-word;
  }
  pre {
    background: #f5f5f5;
    padding: 12px;
    border-radius: 8px;
  }
  blockquote {
    border-left: 4px solid #ccc;
    margin: 16px 0;
    padding: 8px 16px;
    color: #666;
  }
  a { color: #1976d2; text-decoration: none; }
  table { border-collapse: collapse; width: 100%; overflow-x: auto; }
  td, th { border: 1px solid #ddd; padding: 8px; }
</style>
''';

  /// 在系统浏览器中打开指定 URL
  ///
  /// [审计修复 §2.1 第三批] WebView 拦截的外链属内容请求跳转，
  /// 先弹确认对话框（对齐原版 OpenUrlConfirmDialog）再打开 — Qoder
  Future<void> _openUrlExternally(String url) async {
    await openExternalUrlWithConfirm(
      context,
      url: url,
      sourceName: widget.sourceName,
    );
  }

  /// 在系统浏览器中打开文章原文链接
  Future<void> _openInBrowser() async {
    await _openUrlExternally(widget.article.url);
  }

  /// 切换 WebView / 纯文本模式
  void _toggleViewMode() {
    setState(() {
      _useWebView = !_useWebView;
      if (_useWebView && _webViewController == null) {
        _isWebLoading = true;
        _initWebView();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final html = _articleHtml;

    return Scaffold(
      appBar: AppBar(
        title: const Text('文章详情'),
        actions: [
          // 切换渲染模式按钮（仅在支持 WebView 且有内容时显示）
          if (_isWebViewSupported && html != null)
            IconButton(
              icon: Icon(
                _useWebView ? Icons.article_outlined : Icons.web,
              ),
              tooltip: _useWebView ? '切换为纯文本' : '切换为 WebView',
              onPressed: _toggleViewMode,
            ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: '在浏览器中打开',
            onPressed: _openInBrowser,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: '分享',
            onPressed: () async {
              final uri = Uri.tryParse(widget.article.url);
              if (uri != null && await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
      body: _buildBody(context, theme, colorScheme, html),
    );
  }

  /// 构建页面主体内容
  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    String? html,
  ) {
    return Column(
      children: [
        // 文章头部信息（标题、日期、来源、封面图）
        _buildArticleHeader(theme, colorScheme),
        // 文章内容区域
        Expanded(
          child: _buildArticleContent(context, theme, colorScheme, html),
        ),
      ],
    );
  }

  /// 计算封面解码像素宽度（屏幕实际显示宽度 × 设备像素比）
  int _coverDecodeWidth() {
    final mediaQuery = MediaQuery.maybeOf(context);
    final displayWidth = mediaQuery?.size.width ?? 400;
    final pixelRatio = mediaQuery?.devicePixelRatio ?? 1.0;
    return (displayWidth * pixelRatio).round();
  }

  /// 构建文章头部（标题、日期、来源、封面图）
  Widget _buildArticleHeader(ThemeData theme, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Text(
            widget.article.title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          // 元信息：日期 + 来源
          Row(
            children: [
              if (widget.article.pubDate != null &&
                  widget.article.pubDate!.isNotEmpty) ...[
                Icon(Icons.schedule,
                    size: 14, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    widget.article.pubDate!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (widget.sourceName.isNotEmpty) ...[
                const SizedBox(width: 12),
                Icon(Icons.rss_feed,
                    size: 14, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    widget.sourceName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // 封面图
          if (widget.article.imageUrl != null &&
              widget.article.imageUrl!.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                imageUrl: widget.article.imageUrl!,
                width: double.infinity,
                height: 180,
                fit: BoxFit.cover,
                // 限制解码宽度为屏幕实际显示像素宽度，避免大图解码
                memCacheWidth: _coverDecodeWidth(),
                placeholder: (_, _) => Container(
                  height: 180,
                  color: colorScheme.surfaceContainerHighest,
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 8),
          ],
          const Divider(),
        ],
      ),
    );
  }

  /// 构建文章内容区域
  ///
  /// 根据平台和用户选择，使用 WebView 或纯文本渲染。
  Widget _buildArticleContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    String? html,
  ) {
    // 无内容时显示空状态
    if (html == null) {
      return _buildEmptyState(theme, colorScheme);
    }

    // 纯文本模式（桌面端或用户手动切换）
    if (!_useWebView || !_isWebViewSupported) {
      return _buildPlainTextContent(context, theme, html);
    }

    // WebView 模式
    return _buildWebViewContent(theme, colorScheme);
  }

  /// 构建 WebView 内容区域（含加载指示器和错误回退）
  Widget _buildWebViewContent(ThemeData theme, ColorScheme colorScheme) {
    if (_webError != null) {
      // WebView 加载失败时显示错误提示和回退选项
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: colorScheme.error),
              const SizedBox(height: 12),
              Text(
                'WebView 加载失败',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _webError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _toggleViewMode,
                icon: const Icon(Icons.article),
                label: const Text('切换为纯文本'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        // WebView 主体
        WebViewWidget(controller: _webViewController!),
        // 加载指示器覆盖层
        if (_isWebLoading)
          Container(
            color: theme.scaffoldBackgroundColor.withAlpha(200),
            child: const Center(
              child: CircularProgressIndicator(),
            ),
          ),
      ],
    );
  }

  /// 构建纯文本内容（WebView 不可用时的降级方案）
  Widget _buildPlainTextContent(
    BuildContext context,
    ThemeData theme,
    String htmlContent,
  ) {
    final plainText = _stripHtmlTags(htmlContent);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 纯文本提示标签
          if (!_isWebViewSupported)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '当前平台不支持 WebView，已降级为纯文本显示',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // 正文内容
          Text(
            plainText,
            style: theme.textTheme.bodyLarge?.copyWith(
              height: 1.8,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 24),
          // 原文链接按钮
          if (widget.article.url.isNotEmpty)
            Center(
              child: FilledButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Icons.open_in_new),
                label: const Text('查看原文链接'),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// 构建空状态（文章无内容时显示）
  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined,
                size: 64, color: colorScheme.onSurfaceVariant.withAlpha(100)),
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
    );
  }

  /// 去除 HTML 标签（纯文本降级渲染时使用）
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

  @override
  void dispose() {
    _webViewController = null;
    super.dispose();
  }
}
