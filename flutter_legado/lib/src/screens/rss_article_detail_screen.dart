import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/pref_keys.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/deep_link_service.dart';
import '../services/rss_header.dart';
import '../services/rss_web_config.dart';
import '../utils/legado_deep_link.dart';
import '../widgets/empty_state.dart';
import '../widgets/open_url_confirm_dialog.dart';

/// RSS 文章详情 / 阅读页面
///
/// 使用 WebView 渲染文章 HTML 内容（支持 JS 执行）。当 WebView 不可用时
/// （如桌面端），降级为纯文本渲染。
///
/// 批15f：阅读链对齐原版 `ReadRssActivity` —— 源配置 `startHtml`/`startJs`/
/// `injectJs`/`preloadJs`/`style`/`enableJs`/`loadWithBaseUrl`/`showWebLog`/
/// `contentWhitelist`/`contentBlacklist`/`shouldOverrideUrlLoading` 全部接线；
/// 无正文且无 `ruleContent` 时按原版 `RssReadLoadTarget.Url` 直接加载文章
/// 链接（而非只显示空态）。
///
/// 批15g④：`singleUrl` 源强制 URL 直开（对齐 `ReadRssViewModel.kt:127`），
/// 由订阅源列表透传 `rssSortUrls` 解析出的 http(s) 地址。
class RssArticleDetailScreen extends ConsumerStatefulWidget {
  final RssFeedArticle article;
  final String sourceName;

  /// 订阅源 URL（收藏记录 origin；新增入参保持向后兼容，默认空）
  final String sourceUrl;

  /// 已解析的 RSS 源（批15f：列表/历史入口透传，避免重复查库）
  ///
  /// 为空时本页按 [sourceUrl] 从 `getRssSources()` 反查（失败按无源处理）。
  final RssSource? source;

  /// 起始页 HTML（批15f，对齐 `ReadRssActivity.start(startHtml=…)`）
  ///
  /// 非空时优先于文章内容渲染（注入 `startJs`、应用 `startStyle ?? style`）；
  /// 空时回退既有正文/规则正文渲染。
  final String? startHtml;

  /// 规则正文抓取成功回调（审查 P2-7）
  ///
  /// Rust 侧已把正文写回 `rssArticles.description`；列表页在返回前用本回调
  /// 回填内存态（批15f 已补 DB-only 查询，DB 仍为真源）。
  /// 为 null 时（如阅读记录入口）仅本页使用。
  final void Function(String description)? onContentFetched;

  /// 测试专用：强制 WebView 平台判定（null 表示按真实平台判定）
  ///
  /// 桌面测试宿主不支持 webview_flutter，无法真实创建控制器；P0-1 用例
  /// 通过该开关 + 假 `WebViewPlatform` 验证起始页渲染分支。
  @visibleForTesting
  static bool? debugWebViewSupportedOverride;

  const RssArticleDetailScreen({
    super.key,
    required this.article,
    this.sourceName = '',
    this.sourceUrl = '',
    this.source,
    this.startHtml,
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

  /// 已解析的源（widget.source 优先，否则按 sourceUrl 反查）
  RssSource? _source;

  /// 正在反查源（内容区显示加载态，避免闪「暂无内容」）
  bool _isResolvingSource = false;

  /// URL 直开模式（无正文/无 ruleContent，按文章链接加载；对齐
  /// `RssReadLoadTarget.Url`）
  bool _urlMode = false;

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
  /// 测试可经 [RssArticleDetailScreen.debugWebViewSupportedOverride] 覆盖。
  bool get _isWebViewSupported =>
      RssArticleDetailScreen.debugWebViewSupportedOverride ??
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// 是否处于 `startHtml` 起始页模式（批15f 审查 P0-1）
  ///
  /// 起始页模式下 [RssArticleDetailScreen.article] 通常没有正文，渲染条件
  /// 不能只依赖 `_articleHtml != null` 或 `_urlMode`，否则会误落「暂无内容」
  /// 空态（WebView 实际已初始化）。
  bool get _startHtmlMode => widget.startHtml?.trim().isNotEmpty ?? false;

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
    _isResolvingSource = widget.source == null && widget.sourceUrl.isNotEmpty;
    _loadStarState();
    // 批15f：先解析源配置，再决定渲染路径（正文 / 规则正文 / URL 直开）
    unawaited(_bootstrapReading());
  }

  /// 阅读渲染引导（对齐原版 `ReadRssViewModel.initData` 的 target 分支）
  ///
  /// 1. 解析源（widget.source 优先，否则 `getRssSources()` 反查）；
  /// 2. `startHtml` 非空 → 起始页（注入 `startJs`、`startStyle ?? style`）；
  /// 3. 源 `singleUrl` → 强制 URL 直开（对齐 `ReadRssViewModel.kt:124-127`
  ///    的 `ruleContent.isNullOrBlank() || rssSource?.singleUrl == true`，
  ///    批15g④：singleUrl http(s) 由列表页透传解析后的地址）；
  /// 4. 自带 `content`/`description` 有值 → 正文 WebView（`description` 为空
  ///    且 `ruleContent` 非空时并行抓规则正文并替换，审查 P2-1）；
  /// 5. 否则 `ruleContent` 非空 → 抓规则正文；
  /// 6. 否则文章链接/源 URL 非空 → URL 直开（`RssReadLoadTarget.Url`）；
  /// 7. 全都为空 → 空态（浏览器打开原文入口）。
  Future<void> _bootstrapReading() async {
    final source = widget.source ?? await _resolveSource();
    if (!mounted) return;
    setState(() {
      _source = source;
      _isResolvingSource = false;
    });

    final startHtml = widget.startHtml?.trim() ?? '';
    if (startHtml.isNotEmpty) {
      await _initWebView();
      // [批15f 审查 P0-1] 起始页无 `_articleHtml`，控制器创建后显式重建，
      // 让内容区从空态切到 WebView（加载事件之外的兜底刷新）。
      if (mounted) setState(() {});
      return;
    }

    // 批15g④：singleUrl 源无视规则正文，直接加载地址（对齐原版
    // `ReadRssViewModel.kt:127` 的 singleUrl 强制 loadUrl 分支）。
    if (source?.singleUrl ?? false) {
      _urlMode = true;
      await _initWebView();
      if (mounted) setState(() {});
      return;
    }

    final hasContent = _articleHtml != null;
    if (hasContent) {
      await _initWebView();
    }

    final descriptionBlank =
        widget.article.description?.trim().isEmpty ?? true;
    final rule = source?.ruleContent?.trim() ?? '';
    if (descriptionBlank && rule.isNotEmpty && widget.sourceUrl.isNotEmpty) {
      await _loadRuleContent();
      return;
    }
    if (hasContent) return;

    // 无正文、无规则 → 按原版直接加载文章链接（空链接回退源 URL）
    _urlMode = widget.article.url.trim().isNotEmpty ||
        widget.sourceUrl.trim().isNotEmpty;
    if (_urlMode) {
      await _initWebView();
    } else {
      setState(() => _isWebLoading = false);
    }
  }

  /// 按 `sourceUrl` 反查源（失败返回 null，不阻断页面）
  Future<RssSource?> _resolveSource() async {
    if (widget.sourceUrl.isEmpty) return null;
    try {
      final sources = await ref.read(bookApiProvider).getRssSources();
      for (final source in sources) {
        if (source.sourceUrl == widget.sourceUrl) return source;
      }
    } catch (_) {
      // 源读取失败：按无源处理（既有空态/原文入口）
    }
    return null;
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
  /// 历史记录入口按 `link` 形态决定是否传 `sourceUrl`：真实链接由列表页/
  /// 阅读记录条目透传 origin，从而按源规则抓正文；`legacy:` 伪主键或空
  /// 链接视为无链接（不传 origin、不发起正文请求，审查 P2-3/P2-6）。
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
        unawaited(_initWebView());
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

  /// 初始化 WebView 控制器并按源配置加载内容（批15f 阅读链）
  ///
  /// 对齐 `ReadRssActivity.initLiveData`：
  /// - HTML 模式：`loadDataWithBaseURL(baseUrl, clHtml(content, style), …)`，
  ///   `baseUrl = loadWithBaseUrl ? 文章链接（substringBefore("@js")）: null`；
  /// - `startHtml` 模式：先注入 `startJs`，再 `clHtml(html, startStyle ?? style)`，
  ///   baseUrl = `loadWithBaseUrl ? sourceUrl : null`；
  /// - URL 模式：`loadUrl(url, 源 header)`（文章链接优先，空则源 URL）；
  /// - `enableJs == false` → `JavaScriptMode.disabled`（脚本注入全部跳过）。
  Future<void> _initWebView() async {
    if (!_isWebViewSupported) {
      if (mounted) setState(() => _isWebLoading = false);
      return;
    }
    final source = _source;
    final jsEnabled = source?.enableJs ?? true;
    final controller = WebViewController();
    _webViewController = controller;

    await controller.setJavaScriptMode(
      jsEnabled ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
    );
    final headers = parseRssHeaderMap(source?.header);
    // [批15f 审查 P2-2] 源 header 无 UA → 回落全局「其他设置 → UserAgent」
    // （原版 WebView 走全局 UA 设置；全局也未配置则保留系统默认 UA）。
    final userAgent = rssHeaderUserAgent(headers) ?? await _globalUserAgent();
    if (userAgent != null) {
      await controller.setUserAgent(userAgent);
    }
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) {
            setState(() {
              _isWebLoading = true;
              _webError = null;
            });
          }
          if (jsEnabled) unawaited(_onPageStartedScripts());
        },
        onPageFinished: (_) {
          if (mounted) {
            setState(() => _isWebLoading = false);
          }
          if (jsEnabled) unawaited(_onPageFinishedScripts());
        },
        onUrlChange: (_) {
          if (jsEnabled && (source?.showWebLog ?? false)) {
            unawaited(_flushConsoleLogs());
          }
        },
        onWebResourceError: (error) {
          // 仅主框架错误才算页面加载失败（子资源 404 不打断阅读）
          if (!(error.isForMainFrame ?? true)) return;
          if (mounted) {
            setState(() {
              _isWebLoading = false;
              _webError = error.description;
            });
          }
        },
        onNavigationRequest: _handleNavigationRequest,
      ),
    );

    try {
      final startHtml = widget.startHtml?.trim() ?? '';
      if (startHtml.isNotEmpty) {
        // 起始页：注入 startJs → clHtml(startStyle ?? style)
        final processed = rssClHtml(
          rssInjectStartJs(startHtml, source?.startJs),
          style: source?.startStyle ?? source?.style,
          preloadJs: source?.preloadJs,
        );
        final baseUrl = (source?.loadWithBaseUrl ?? true)
            ? _htmlBaseUrl(widget.sourceUrl)
            : null;
        await controller.loadHtmlString(processed, baseUrl: baseUrl);
        return;
      }
      // URL 直开优先于正文：singleUrl 源即使带正文也按地址加载
      // （对齐 `ReadRssViewModel.kt:127`，批15g④）。
      if (_urlMode) {
        final target = widget.article.url.trim().isNotEmpty
            ? widget.article.url.trim()
            : widget.sourceUrl.trim();
        final uri = Uri.tryParse(target);
        if (uri == null) {
          if (mounted) {
            setState(() {
              _isWebLoading = false;
              _webError = '无效的文章链接';
            });
          }
          return;
        }
        await controller.loadRequest(uri, headers: headers);
        return;
      }
      final html = _articleHtml;
      if (html != null) {
        // 无源信息时保留既有响应式样式（历史入口/旧数据兼容）
        final processed = source == null
            ? _wrapHtmlWithStyle(html)
            : rssClHtml(
                html,
                style: source.style,
                preloadJs: source.preloadJs,
              );
        final baseUrl = source == null || source.loadWithBaseUrl
            ? _htmlBaseUrl(widget.article.url)
            : null;
        await controller.loadHtmlString(processed, baseUrl: baseUrl);
        return;
      }
      if (mounted) setState(() => _isWebLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isWebLoading = false;
          _webError = '$e';
        });
      }
    }
  }

  /// 页面开始：注入预加载 JS / console 钩子 / `java` 桩（仅 enableJs）
  Future<void> _onPageStartedScripts() async {
    final controller = _webViewController;
    final source = _source;
    if (controller == null) return;
    try {
      // URL 模式无法重写主文档 <head>（Flutter WebView 无 shouldInterceptRequest），
      // 退化为页面开始即执行 preloadJs（已登记差异）
      final preloadJs = source?.preloadJs?.trim() ?? '';
      if (_urlMode && preloadJs.isNotEmpty) {
        await controller.runJavaScript(preloadJs);
      }
      if (source?.showWebLog ?? false) {
        await controller.runJavaScript(kRssConsoleHookScript);
      }
      final overrideJs = source?.shouldOverrideUrlLoading?.trim() ?? '';
      if (overrideJs.isNotEmpty) {
        await controller.runJavaScript(kRssJavaStubScript);
      }
    } catch (e) {
      debugPrint('[RSS WebView] onPageStarted 脚本注入失败: $e');
    }
  }

  /// 页面完成：执行 `injectJs` 并回读 console 日志（`showWebLog`）
  Future<void> _onPageFinishedScripts() async {
    final controller = _webViewController;
    final source = _source;
    if (controller == null) return;
    try {
      final injectJs = source?.injectJs?.trim() ?? '';
      if (injectJs.isNotEmpty) {
        await controller.runJavaScript(injectJs);
      }
      if (source?.showWebLog ?? false) {
        await _flushConsoleLogs();
      }
    } catch (e) {
      debugPrint('[RSS WebView] onPageFinished 脚本注入失败: $e');
    }
  }

  /// 回读 `console.*` 缓冲并输出（对齐原版 `onConsoleMessage` + `showWebLog`）
  Future<void> _flushConsoleLogs() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      final raw = await controller.runJavaScriptReturningResult(
        kRssConsoleFlushScript,
      );
      final logs = rssParseConsoleLogs(raw);
      if (logs.isEmpty) return;
      final tag = _source?.sourceName ?? widget.sourceName;
      for (final line in logs) {
        debugPrint('[RSS WebView][$tag] $line');
      }
    } catch (e) {
      debugPrint('[RSS WebView] 读取 console 日志失败: $e');
    }
  }

  /// 导航请求处理（对齐 `ReadRssActivity.kt:770-808` + 白/黑名单）
  ///
  /// 1. `shouldOverrideUrlLoading` 非空 → JS 求值（`url` + `java` 桩），
  ///    结果经 [rssShouldOverrideResult] 归一，true 拦截；
  /// 2. 白/黑名单判定（仅主框架；子资源拦截 Flutter 无面，登记差异）；
  /// 3. http/https → WebView 内导航；`legado:`/`yuedu:` → 站内关联导入
  ///    （复用 [DeepLinkService.handleUrl]）；其余 scheme → 确认后外部打开
  ///    并阻止 WebView 导航。
  Future<NavigationDecision> _handleNavigationRequest(
    NavigationRequest request,
  ) async {
    final url = request.url;
    if (url.isEmpty ||
        url.startsWith('data:') ||
        url.startsWith('about:')) {
      return NavigationDecision.navigate;
    }
    final source = _source;
    final controller = _webViewController;
    final overrideJs = source?.shouldOverrideUrlLoading?.trim() ?? '';
    if (controller != null &&
        overrideJs.isNotEmpty &&
        (source?.enableJs ?? true)) {
      try {
        final result = await controller.runJavaScriptReturningResult(
          rssShouldOverrideScript(overrideJs, url),
        );
        if (rssShouldOverrideResult(result)) {
          debugPrint('[RSS WebView] shouldOverrideUrlLoading 拦截: $url');
          return NavigationDecision.prevent;
        }
      } catch (e) {
        debugPrint('[RSS WebView] shouldOverrideUrlLoading 执行失败: $e');
      }
    }

    final rule = rssNavigationRuleDecision(
      url: url,
      whitelist: source?.contentWhitelist,
      blacklist: source?.contentBlacklist,
    );
    if (rule == RssNavigationRule.block) {
      debugPrint('[RSS WebView] 命中内容白/黑名单，已拦截: $url');
      return NavigationDecision.prevent;
    }

    final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      return NavigationDecision.navigate;
    }
    // [批15f 审查 P2-3] legado:/yuedu: 走站内关联导入（复用系统深链入口，
    // 对齐原版 openUrl 对该协议直进 OnLineImportActivity 不弹外跳确认），
    // 不再交外部浏览器处理。
    if (LegadoDeepLink.isImportScheme(url)) {
      unawaited(DeepLinkService.instance.handleUrl(url));
      return NavigationDecision.prevent;
    }
    unawaited(_openUrlExternally(url));
    return NavigationDecision.prevent;
  }

  /// 全局 UserAgent（`PrefKeys.userAgent`；空/读取失败返回 null 用系统默认）
  ///
  /// 批15f 审查 P2-2：源 `header` 未配置 `User-Agent` 时回落用户全局设置，
  /// 对齐原版 WebView 读取 `AppConfig.userAgent` 的行为。
  Future<String?> _globalUserAgent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(PrefKeys.userAgent)?.trim() ?? '';
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// WebView baseUrl（文章链接去掉规则尾巴；空串回退 null）
  ///
  /// 对齐上游 `NetworkUtils.getAbsoluteURL(it.origin, it.link).substringBefore("@js")`。
  static String? _htmlBaseUrl(String link) {
    final normalized = link.split('@js').first.trim();
    return normalized.isEmpty ? null : normalized;
  }

  /// 为 HTML 内容注入响应式样式（无源信息时的既有降级实现）
  ///
  /// 有源配置时改走 [rssClHtml]（逐行对齐原版 `clHtml`：`style` 语义、
  /// `preloadJs` 内联、默认移动端样式）。
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
        unawaited(_initWebView());
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
          // 切换渲染模式按钮（仅在支持 WebView、有正文且非起始页时显示）
          if (_isWebViewSupported && html != null && !_startHtmlMode)
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

  /// 封面图请求头（源静态 header；空时返回 null 保持 CachedNetworkImage 默认）
  Map<String, String>? _coverHeaders() {
    final headers = parseRssHeaderMap(
      _source?.header ?? widget.source?.header,
    );
    return headers.isEmpty ? null : headers;
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
                // 源静态 header 透传（防盗链；coverDecodeJs 解密登记 15g）
                httpHeaders: _coverHeaders(),
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
    // [批15f] 源配置解析中：避免先闪「暂无内容」
    if (_isResolvingSource) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

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

    // [批15f 审查 P0-1] startHtml 起始页优先于文章自带内容渲染（与
    // `_bootstrapReading` / `_initWebView` 的分支顺序一致）。起始页模式
    // 通常 `_articleHtml == null`，不能只依赖下方 URL 直开条件，否则控制器
    // 已初始化却永远显示「暂无内容」空态。
    if (_startHtmlMode &&
        _isWebViewSupported &&
        _useWebView &&
        _webViewController != null) {
      return _buildWebViewContent(theme, colorScheme);
    }

    // [批15f] URL 直开模式（无正文/无 ruleContent，对齐
    // `RssReadLoadTarget.Url`）：直接渲染文章链接的 WebView 页面。
    // 批15g④：singleUrl 源强制走本分支（即使文章带正文也以地址为准）。
    if (_urlMode &&
        _isWebViewSupported &&
        _useWebView &&
        _webViewController != null) {
      return _buildWebViewContent(theme, colorScheme);
    }

    // 无内容时显示空状态
    // [LAYOUT_PLAN P4 收尾] 自绘空态并入 EmptyState（保留「浏览器查看原文」动作）
    if (html == null) {
      return EmptyState(
        icon: Symbols.article_rounded,
        title: '暂无内容',
        // 无链接（空串/legacy 伪主键）时没有可打开的原文
        action: widget.article.url.isEmpty
            ? null
            : OutlinedButton.icon(
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
    final controller = _webViewController;
    if (controller == null) {
      return EmptyState(
        icon: Symbols.article_rounded,
        title: '暂无内容',
        action: widget.article.url.isEmpty
            ? null
            : OutlinedButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Symbols.open_in_browser_rounded),
                label: const Text('在浏览器中查看原文'),
              ),
      );
    }
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
              if (_urlMode || _startHtmlMode)
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _isWebLoading = true;
                      _webError = null;
                    });
                    unawaited(_initWebView());
                  },
                  icon: const Icon(Symbols.refresh_rounded),
                  label: const Text('重试'),
                )
              else
                FilledButton.icon(
                  onPressed: _toggleViewMode,
                  icon: const Icon(Symbols.article_rounded),
                  label: const Text('切换为纯文本'),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Symbols.open_in_browser_rounded),
                label: const Text('在浏览器中打开'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        // WebView 主体
        WebViewWidget(controller: controller),
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
