import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../widgets/empty_state.dart';
import '../widgets/open_url_confirm_dialog.dart';

/// RSS 文章详情页面
///
/// 使用 WebView 渲染文章 HTML 内容（支持 JS 执行）。
/// 当 WebView 不可用时（如桌面端），降级为纯文本渲染。
class RssArticleDetailScreen extends ConsumerStatefulWidget {
  final RssFeedArticle article;
  final String sourceName;

  /// 订阅源 URL（收藏记录 origin；新增入参保持向后兼容，默认空）
  final String sourceUrl;

  /// 规则正文抓取成功回调（审查 P2-7）
  ///
  /// Rust 侧已把正文写回 `rssArticles.description`；列表页当前无「只读
  /// DB」FFI，故由本页把正文回填给列表页内存态，返回列表即可看到新正文。
  /// 为 null 时（如阅读记录入口）仅本页使用。
  final void Function(String description)? onContentFetched;

  const RssArticleDetailScreen({
    super.key,
    required this.article,
    this.sourceName = '',
    this.sourceUrl = '',
    this.onContentFetched,
  });

  @override
  ConsumerState<RssArticleDetailScreen> createState() =>
      _RssArticleDetailScreenState();
}

class _RssArticleDetailScreenState
    extends ConsumerState<RssArticleDetailScreen> {
  /// WebView 控制器（仅在支持 WebView 的平台初始化）
  WebViewController? _webViewController;

  /// 标记 WebView 是否加载完成
  bool _isWebLoading = true;

  /// WebView 加载错误信息
  String? _webError;

  /// 当前是否使用 WebView 模式（可切换为纯文本）
  bool _useWebView = true;

  // [批15c | 2026-10-26] 规则正文拉取（对齐 ReadRssViewModel.loadContent）：
  // article.description 为空且源配置 ruleContent 时，经 `rssFetchContent`
  // 抓取正文（Rust 侧负责抓取/分页/写回）；自带 content 仅作显示回退。
  bool _isContentLoading = false;
  String? _contentError;
  String? _fetchedContent;

  // [UI-fix v2.0.2 | 2026-08-06] 详情收藏（对标原版 RssFavoritesDialog：
  // 接通 addRssStar/deleteRssStar/isStarred FFI） — Qoder
  bool _isStarred = false;
  bool _starBusy = false;

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

  /// 获取文章 HTML 内容
  ///
  /// 优先规则抓取结果（仅在 `description` 为空时发起），其次文章自带
  /// `content`，最后 `description`。抓取失败时回落到自带内容，不影响阅读。
  ///
  /// 空判定统一按 `isNullOrBlank` 口径（trim 后为空算空，审查 P2-3）。
  String? get _articleHtml {
    if (_fetchedContent != null && _fetchedContent!.trim().isNotEmpty) {
      return _fetchedContent;
    }
    if (widget.article.content?.trim().isNotEmpty ?? false) {
      return widget.article.content;
    }
    if (widget.article.description?.trim().isNotEmpty ?? false) {
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
    _loadStarState();
    // [批15c] description 为空时按源正文规则拉取
    _maybeLoadRuleContent();
  }

  /// `description` 为空且源配置 `ruleContent` 时拉取规则正文
  ///
  /// 对齐原版 `ReadRssViewModel.resolveRssReadLoadTarget`（`ReadRssViewModel.kt:46-59`）：
  /// - `description` 为空（`isNullOrBlank`，trim 后为空，审查 P2-3）→ 拉取；
  /// - `ruleContent` 为空 → 走原文 URL（本页空态「在浏览器中查看原文」）；
  /// - 否则按规则抓取正文（Rust `rssFetchContent`，成功后 Rust 侧写回
  ///   `rssArticles.description` / `rssStars.description`）。
  ///
  /// 本页渲染优先级为「规则正文 → 自带 content → description」：自带
  /// `content` 有值时仍会按 `description` 判定发请求（对齐原版读路径只认
  /// description，审查 P2-1），失败时回落显示自带 content。
  ///
  /// 历史记录入口只带 `sourceName` 不含 `sourceUrl`，无从判定源规则，
  /// 保持既有行为（空态 + 浏览器打开原文）；「历史入口暂不抓规则正文」的
  /// 收敛属批15d/15f（契约 §2.5 批15c 注，审查 P2-5）。
  Future<void> _maybeLoadRuleContent() async {
    if (widget.sourceUrl.isEmpty) return;
    if (widget.article.description?.trim().isNotEmpty ?? false) return;

    // 源正文规则非空才触发（避免对无规则源发无意义请求）
    String? ruleContent;
    try {
      final sources = await ref.read(bookApiProvider).getRssSources();
      for (final source in sources) {
        if (source.sourceUrl == widget.sourceUrl) {
          ruleContent = source.ruleContent;
          break;
        }
      }
    } catch (_) {
      // 源读取失败不阻断页面：按无规则处理（显示空态/自带内容）
      return;
    }
    if (!mounted) return;
    if (ruleContent == null || ruleContent.trim().isEmpty) return;
    await _loadRuleContent();
  }

  /// 调用 `rssFetchContent` 拉取正文（加载态/失败提示/成功渲染）
  Future<void> _loadRuleContent() async {
    setState(() {
      _isContentLoading = true;
      _contentError = null;
    });
    try {
      final content = await ref.read(bookApiProvider).rssFetchContent(
            widget.sourceUrl,
            widget.article.url,
            // 审查 P2-4：透传分类名，按 (origin, link, sort) 主键精确写回；
            // 空串按缺省（FFI 侧 order DESC 取首行）处理。
            sort: widget.article.sort.isEmpty ? null : widget.article.sort,
          );
      if (!mounted) return;
      setState(() {
        _isContentLoading = false;
        // 空正文：原版交给 UI 显示空白，这里回落「暂无内容」空态/自带内容
        _fetchedContent = content.trim().isEmpty ? null : content;
      });
      // 审查 P2-7：回填列表页内存态（DB 已由 Rust 写回）
      if (_fetchedContent != null) {
        widget.onContentFetched?.call(_fetchedContent!);
      }
      // 规则正文就绪后（重新）初始化 WebView，加载新内容
      if (_fetchedContent != null && _isWebViewSupported && _useWebView) {
        _isWebLoading = true;
        _initWebView();
      }
    } catch (e) {
      if (!mounted) return;
      final hasFallback = widget.article.content?.trim().isNotEmpty ?? false;
      setState(() {
        _isContentLoading = false;
        _contentError = '$e';
      });
      // 自带 content 可用时继续阅读自带内容，仅用轻提示告知规则正文失败；
      // 审查 P2-8：降级态同样提供「重试」入口。
      if (hasFallback) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('正文加载失败，已显示文章自带内容'),
            action: SnackBarAction(label: '重试', onPressed: _loadRuleContent),
          ),
        );
      }
    }
  }

  /// 加载收藏状态（isStarred FFI，失败静默保持未收藏）
  Future<void> _loadStarState() async {
    try {
      final starred = await ref
          .read(bookApiProvider)
          .isStarred(widget.article.url);
      if (mounted) setState(() => _isStarred = starred);
    } catch (_) {}
  }

  /// 收藏/取消收藏（对标原版 RssFavoritesDialog.favoriteArticle）
  Future<void> _toggleStar() async {
    if (_starBusy) return;
    setState(() => _starBusy = true);
    final api = ref.read(bookApiProvider);
    try {
      if (_isStarred) {
        await api.deleteRssStar(widget.article.url);
      } else {
        final article = widget.article;
        // 审查 P2-6：抓取成功后的收藏使用抓取到的正文（对齐
        // ReadRssViewModel.kt:157-162 的「收藏描述 = body」口径）。
        // 注：Rust `rssStarAdd` 当前只取 origin/title/link（其余默认，契约
        // §2.5 批15c 注），此处传递保证 Mock/后续扩展行为一致。
        final fetched = _fetchedContent;
        await api.addRssStar(
          RssStar(
            origin: widget.sourceUrl,
            sort: article.sort,
            title: article.title,
            starTime: DateTime.now().millisecondsSinceEpoch,
            link: article.url,
            pubDate: article.pubDate,
            description: fetched ?? article.description,
            content: article.content,
            image: article.imageUrl,
            group: widget.sourceName.isEmpty ? '默认分组' : widget.sourceName,
          ),
        );
      }
      if (!mounted) return;
      setState(() => _isStarred = !_isStarred);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isStarred ? '已收藏' : '已取消收藏')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('收藏操作失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _starBusy = false);
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
    // 审查 P1-2：补 baseUrl = 文章链接（对齐上游 ReadRssActivity.kt:406-411
    // 的 `loadDataWithBaseURL(baseUrl, html, …)`），否则相对图片/链接无法解析。
    // 上游对 link 做 `substringBefore("@js")` 归一；`loadWithBaseUrl == false`
    // 时上游传 null，该源字段接线属批15f（契约 §2.5 批15c 注交叉引用）。
    final baseUrl = _htmlBaseUrl(widget.article.url);
    final styledHtml = _wrapHtmlWithStyle(html);
    _webViewController!.loadHtmlString(styledHtml, baseUrl: baseUrl);
  }

  /// WebView baseUrl（文章链接去掉规则尾巴；空串回退 null）
  ///
  /// 对齐上游 `NetworkUtils.getAbsoluteURL(it.origin, it.link).substringBefore("@js")`。
  static String? _htmlBaseUrl(String link) {
    final normalized = link.split('@js').first.trim();
    return normalized.isEmpty ? null : normalized;
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

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: const Text('文章详情'),
        actions: [
          // [UI-fix v2.0.2 | 2026-08-06] 收藏入口（对标原版 menu_rss_star）— Qoder
          IconButton(
            icon: Icon(_isStarred ? Symbols.star_rounded : Symbols.star_rounded),
            tooltip: _isStarred ? '取消收藏' : '收藏',
            onPressed: _starBusy ? null : _toggleStar,
          ),
          // 切换渲染模式按钮（仅在支持 WebView 且有内容时显示）
          if (_isWebViewSupported && html != null)
            IconButton(
              icon: Icon(
                _useWebView ? Symbols.article_rounded : Symbols.web_rounded,
              ),
              tooltip: _useWebView ? '切换为纯文本' : '切换为 WebView',
              onPressed: _toggleViewMode,
            ),
          IconButton(
            icon: const Icon(Symbols.open_in_browser_rounded),
            tooltip: '在浏览器中打开',
            onPressed: _openInBrowser,
          ),
          IconButton(
            icon: const Icon(Symbols.share_rounded),
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
      // [LAYOUT_PLAN P2] 页面水平边距 16dp（全局标尺）
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
                Icon(Symbols.schedule_rounded,
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
                Icon(Symbols.rss_feed_rounded,
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
              // [LAYOUT_PLAN P2] 封面圆角 12dp（内容图规格）
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
    // [批15c] 规则正文加载中：仅在无可展示内容时占用内容区；
    // 自带 content 可用时继续显示自带内容，不打断阅读。
    if (_isContentLoading && html == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text(
              '正在加载正文…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // [批15c] 规则正文加载失败：提示 + 重试 + 浏览器打开原文
    if (_contentError != null && html == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.error_rounded, size: 48, color: colorScheme.error),
              const SizedBox(height: 12),
              Text(
                '加载正文失败',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _contentError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadRuleContent,
                icon: const Icon(Symbols.refresh_rounded),
                label: const Text('重试'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Symbols.open_in_browser_rounded),
                label: const Text('在浏览器中查看原文'),
              ),
            ],
          ),
        ),
      );
    }

    // 无内容时显示空状态
    // [LAYOUT_PLAN P4 收尾] 自绘空态并入 EmptyState（保留「浏览器查看原文」动作）
    if (html == null) {
      return EmptyState(
        icon: Symbols.article_rounded,
        title: '暂无内容',
        action: OutlinedButton.icon(
          onPressed: _openInBrowser,
          icon: const Icon(Symbols.open_in_browser_rounded),
          label: const Text('在浏览器中查看原文'),
        ),
      );
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
              Icon(Symbols.error_rounded,
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
                icon: const Icon(Symbols.article_rounded),
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
      // [LAYOUT_PLAN P2] 正文区边距统一 16dp（全局标尺）
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
              // [LAYOUT_PLAN P2] 提示条走 tonal（surfaceContainerHighest）
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Symbols.info_rounded,
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
                icon: const Icon(Symbols.open_in_new_rounded),
                label: const Text('查看原文链接'),
              ),
            ),
          const SizedBox(height: 16),
        ],
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
