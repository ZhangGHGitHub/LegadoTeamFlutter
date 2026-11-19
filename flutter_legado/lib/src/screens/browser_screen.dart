import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../l10n/app_strings.dart';
import '../utils/webview_support.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 内置浏览器页面
///
/// [UI-fix v2.0.2 | 2026-08-06] 双模实现（Task #114 平台桥接参数扩展 — QoderCN）：
/// - WebView 支持平台（Android/iOS/macOS）且携带初始 URL/HTML 时，
///   内嵌真实 WebView（webview_flutter）页内渲染，供平台桥接
///   （showBrowser/startBrowser/openUrl）承载应用内浏览；
/// - 其余场景（桌面无 WebView 实现）保持 url_launcher 降级方案：
///   内部维护导航历史栈（前进/后退/刷新），页面在系统浏览器中打开，
///   并提供 JavaScript 片段提取助手。
class BrowserScreen extends StatefulWidget {
  /// 初始 URL（可选）
  final String? initialUrl;

  /// 初始 HTML 内容（可选，供平台桥接 showBrowser 携带页面内容加载）
  final String? initialHtml;

  /// 页面标题（可选，缺省「内置浏览器」）
  final String? title;

  const BrowserScreen({super.key, this.initialUrl, this.initialHtml, this.title});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _urlController = TextEditingController();

  /// 导航历史栈
  final List<String> _history = [];
  int _currentIndex = -1;

  /// JS 提取结果粘贴区
  final _jsResultController = TextEditingController();

  /// 内嵌 WebView 控制器（仅 WebView 支持平台且携带初始内容时创建）— QoderCN
  WebViewController? _webViewController;

  /// 内嵌 WebView 页面是否加载完成（进度指示用）
  bool _embeddedLoading = true;

  /// 内嵌 WebView 当前页面 URL（onPageStarted/Finished，主框架
  /// HTTP 错误判定时与 request URL 匹配用）
  String _embeddedStartedUrl = '';

  /// 当前平台是否支持内嵌 WebView（统一判定见 [isWebViewPlatformSupported]）
  bool get _webViewSupported => isWebViewPlatformSupported;

  static Map<String, String> get _jsSnippets => {
        AppStrings.jsSnippetPageTitle: 'document.title',
        AppStrings.jsSnippetBodyText: 'document.body.innerText',
        AppStrings.jsSnippetAllLinks:
            'JSON.stringify([...document.querySelectorAll("a")].map(a => ({text: a.innerText.trim(), href: a.href})).filter(l => l.text && l.href.startsWith("http")))',
        AppStrings.jsSnippetChapterList:
            'JSON.stringify([...document.querySelectorAll("#list dd a, .listmain dd a, #chapterlist a")].map(a => ({title: a.innerText.trim(), url: a.href})))',
        AppStrings.jsSnippetImageUrls:
            'JSON.stringify([...document.querySelectorAll("img")].map(i => i.src).filter(s => s.startsWith("http")))',
      };

  String? get _currentUrl =>
      _currentIndex >= 0 && _currentIndex < _history.length
          ? _history[_currentIndex]
          : null;

  bool get _canGoBack => _currentIndex > 0;
  bool get _canGoForward => _currentIndex < _history.length - 1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialUrl?.trim() ?? '';
    final html = widget.initialHtml?.trim() ?? '';
    if (_webViewSupported && (initial.isNotEmpty || html.isNotEmpty)) {
      // 内嵌真实 WebView 模式（Task #114 平台桥接承载）— QoderCN
      _initEmbeddedWebView(initial, html);
    } else if (initial.isNotEmpty) {
      _urlController.text = initial;
      _navigate(initial);
    }
  }

  /// 初始化内嵌 WebView 并加载初始内容（html 优先，对齐 Kotlin
  /// BackstageWebView loadDataWithBaseURL(url, html) 语义）— QoderCN
  void _initEmbeddedWebView(String url, String html) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (startedUrl) {
          if (mounted) {
            setState(() {
              _embeddedLoading = true;
              _embeddedStartedUrl = startedUrl;
            });
          }
        },
        onPageFinished: (finishedUrl) {
          if (mounted) {
            setState(() {
              _embeddedLoading = false;
              _embeddedStartedUrl = finishedUrl;
              _urlController.text = finishedUrl;
            });
          }
        },
        onWebResourceError: (error) {
          if (mounted) {
            setState(() => _embeddedLoading = false);
            // [iOS 视角F A1] 主框架加载失败上屏提示（子资源错误不打扰）
            if (error.isForMainFrame ?? false) {
              _reportLoadFailure(
                  AppStrings.pageLoadFailedWithReason(error.description));
            }
          }
        },
        onHttpError: (error) {
          final status = error.response?.statusCode;
          if (status == null || status < 400) return;
          // 主框架判定：iOS WKWebView 的 onHttpError 仅源自主框架导航
          //（request 为 null，子资源不触发）直接提示；Android
          // onReceivedHttpError 对子资源（图片 404 等）也触发，按当前
          // 页面 URL 匹配，避免误报。
          final requestUri = error.request?.uri;
          if (requestUri == null ||
              (_embeddedStartedUrl.isNotEmpty &&
                  requestUri.toString() == _embeddedStartedUrl)) {
            _reportLoadFailure(AppStrings.pageLoadFailedHttp(status));
          }
        },
      ));
    if (html.isNotEmpty) {
      final base = Uri.tryParse(url);
      controller.loadHtmlString(
        html,
        baseUrl: base != null && base.hasScheme ? url : null,
      );
      if (url.isNotEmpty) _urlController.text = url;
    } else {
      final uri = Uri.tryParse(_normalize(url));
      if (uri != null) {
        controller.loadRequest(uri);
        _urlController.text = uri.toString();
      }
    }
    _webViewController = controller;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _jsResultController.dispose();
    super.dispose();
  }

  /// [iOS 视角F A1] 内嵌 WebView 主框架加载失败上屏提示
  ///（过去失败只留白屏，进度条停住后用户无从归因）
  void _reportLoadFailure(String message) {
    if (!mounted) return;
    debugPrint('[Browser] $message');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 规范化 URL（自动补全协议）
  String _normalize(String input) {
    final trimmed = input.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return 'https://$trimmed';
  }

  void _navigate(String input) {
    final url = _normalize(input);
    final embedded = _webViewController;
    if (embedded != null) {
      // 内嵌模式：页内加载（Task #114）— QoderCN
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      setState(() => _urlController.text = url);
      embedded.loadRequest(uri);
      return;
    }
    setState(() {
      // 截断前进历史
      if (_currentIndex < _history.length - 1) {
        _history.removeRange(_currentIndex + 1, _history.length);
      }
      _history.add(url);
      _currentIndex = _history.length - 1;
      _urlController.text = url;
    });
    _openExternal(url);
  }

  void _goBack() {
    final embedded = _webViewController;
    if (embedded != null) {
      embedded.canGoBack().then((can) {
        if (can) embedded.goBack();
      });
      return;
    }
    if (!_canGoBack) return;
    setState(() => _currentIndex--);
    final url = _currentUrl;
    if (url != null) {
      _urlController.text = url;
      _openExternal(url);
    }
  }

  void _goForward() {
    final embedded = _webViewController;
    if (embedded != null) {
      embedded.canGoForward().then((can) {
        if (can) embedded.goForward();
      });
      return;
    }
    if (!_canGoForward) return;
    setState(() => _currentIndex++);
    final url = _currentUrl;
    if (url != null) {
      _urlController.text = url;
      _openExternal(url);
    }
  }

  void _refresh() {
    final embedded = _webViewController;
    if (embedded != null) {
      embedded.reload();
      return;
    }
    final url = _currentUrl;
    if (url != null) _openExternal(url);
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.cannotOpenUrl(url))),
        );
      }
    }
  }

  Future<void> _copySnippet(String name, String snippet) async {
    await Clipboard.setData(ClipboardData(text: snippet));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.snippetCopied(name))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final embedded = _webViewController;
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: Text(widget.title?.isNotEmpty == true
            ? widget.title!
            : AppStrings.builtInBrowser),
        actions: [
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            tooltip: AppStrings.refreshAction,
            onPressed: embedded != null || _currentUrl != null
                ? _refresh
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildAddressBar(theme),
          _buildToolbar(theme),
          const Divider(height: 1),
          Expanded(
            child: embedded != null
                ? _buildEmbeddedWebView(theme, embedded)
                : (_currentUrl == null
                    ? _buildEmpty(theme)
                    : _buildContent(theme)),
          ),
        ],
      ),
    );
  }

  /// 内嵌 WebView 内容区（Task #114 平台桥接承载）— QoderCN
  Widget _buildEmbeddedWebView(ThemeData theme, WebViewController controller) {
    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_embeddedLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _buildAddressBar(ThemeData theme) {
    return Padding(
      // [LAYOUT_PLAN P3] 页面水平边距统一 16dp（全局标尺）
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlController,
              textInputAction: TextInputAction.go,
              onSubmitted: _navigate,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Symbols.public_rounded, size: 20),
                hintText: AppStrings.browserUrlHint,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              final text = _urlController.text.trim();
              if (text.isNotEmpty) _navigate(text);
            },
            child: Text(AppStrings.go),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return Padding(
      // [LAYOUT_PLAN P3] 页面水平边距统一 16dp（全局标尺）
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Symbols.arrow_back_rounded),
            tooltip: AppStrings.goBackLabel,
            onPressed: _canGoBack ? _goBack : null,
          ),
          IconButton(
            icon: const Icon(Symbols.arrow_forward_rounded),
            tooltip: AppStrings.goForwardLabel,
            onPressed: _canGoForward ? _goForward : null,
          ),
          const Spacer(),
          if (_currentUrl != null)
            Text(
              '${_currentIndex + 1}/${_history.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                // [FIX 2026-09-04] 正文次要文字走 onSurfaceVariant（outline 仅用于边框/装饰图标）
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.travel_explore_rounded, size: 64,
              color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(AppStrings.browserEmptyTitle, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text(
            AppStrings.browserEmptyDesc,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final url = _currentUrl!;
    final uri = Uri.tryParse(url);
    return ListView(
      // [LAYOUT_PLAN P3] 页面水平边距统一 16dp（全局标尺）
      padding: const EdgeInsets.all(16),
      children: [
        // 当前页面信息
        Card(
          // [LAYOUT_PLAN P3] 分组卡圆角 16dp；卡内统一 16dp
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Symbols.language_rounded, size: 20,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    // [FIX 2026-09-19 P2-13②] host 限宽 + 省略号截断，防 Row 右溢
                    Flexible(
                      child: Text(
                        uri?.host ?? url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Symbols.open_in_browser_rounded, size: 18),
                      label: Text(AppStrings.openExternally),
                      onPressed: () => _openExternal(url),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  url,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    // [FIX 2026-09-04] 正文次要文字走 onSurfaceVariant（outline 仅用于边框/装饰图标）
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // JS 提取助手
        Text(AppStrings.jsExtractHelper, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          AppStrings.jsExtractHelperDesc,
          style: theme.textTheme.bodySmall?.copyWith(
            // [FIX 2026-09-04] 正文次要文字走 onSurfaceVariant（outline 仅用于边框/装饰图标）
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _jsSnippets.entries
              .map((e) => ActionChip(
                    avatar: const Icon(Symbols.content_copy_rounded, size: 16),
                    label: Text(e.key),
                    onPressed: () => _copySnippet(e.key, e.value),
                  ))
              .toList(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _jsResultController,
          maxLines: 6,
          decoration: InputDecoration(
            labelText: AppStrings.executeResult,
            hintText: AppStrings.executeResultHint,
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Symbols.close_rounded, size: 18),
              label: Text(AppStrings.clearResult),
              onPressed: () => _jsResultController.clear(),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Symbols.content_paste_rounded, size: 18),
              label: Text(AppStrings.paste),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  _jsResultController.text = data!.text!;
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}
