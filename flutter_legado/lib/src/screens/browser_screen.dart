import 'dart:io';

import 'package:flutter/material.dart';
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

  /// 当前平台是否支持内嵌 WebView（对齐 rss_article_detail_screen 判定）
  bool get _webViewSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  static const _jsSnippets = <String, String>{
    '获取页面标题': 'document.title',
    '获取正文文本': 'document.body.innerText',
    '获取所有链接':
        'JSON.stringify([...document.querySelectorAll("a")].map(a => ({text: a.innerText.trim(), href: a.href})).filter(l => l.text && l.href.startsWith("http")))',
    '获取章节列表':
        'JSON.stringify([...document.querySelectorAll("#list dd a, .listmain dd a, #chapterlist a")].map(a => ({title: a.innerText.trim(), url: a.href})))',
    '获取图片地址':
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
        onPageStarted: (_) {
          if (mounted) setState(() => _embeddedLoading = true);
        },
        onPageFinished: (finishedUrl) {
          if (mounted) {
            setState(() {
              _embeddedLoading = false;
              _urlController.text = finishedUrl;
            });
          }
        },
        onWebResourceError: (_) {
          if (mounted) setState(() => _embeddedLoading = false);
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
          SnackBar(content: Text('无法打开: $url')),
        );
      }
    }
  }

  Future<void> _copySnippet(String name, String snippet) async {
    await Clipboard.setData(ClipboardData(text: snippet));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制「$name」脚本，粘贴到浏览器控制台执行')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final embedded = _webViewController;
    return Scaffold(
      appBar: LegadoAppBar(
        title: Text(widget.title?.isNotEmpty == true
            ? widget.title!
            : '内置浏览器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlController,
              textInputAction: TextInputAction.go,
              onSubmitted: _navigate,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.public, size: 20),
                hintText: '输入网址，如 https://example.com',
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
            child: const Text('访问'),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '后退',
            onPressed: _canGoBack ? _goBack : null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            tooltip: '前进',
            onPressed: _canGoForward ? _goForward : null,
          ),
          const Spacer(),
          if (_currentUrl != null)
            Text(
              '${_currentIndex + 1}/${_history.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
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
          Icon(Icons.travel_explore, size: 64,
              color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('输入网址开始浏览', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text(
            '页面将在系统浏览器中打开，\n可配合 JS 提取助手抓取结果',
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
      padding: const EdgeInsets.all(16),
      children: [
        // 当前页面信息
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.language, size: 20,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      uri?.host ?? url,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: const Text('外部打开'),
                      onPressed: () => _openExternal(url),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  url,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.outline,
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
        Text('JavaScript 提取助手', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '复制脚本 → 在外部浏览器控制台（F12）执行 → 将结果粘贴到下方',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _jsSnippets.entries
              .map((e) => ActionChip(
                    avatar: const Icon(Icons.copy, size: 16),
                    label: Text(e.key),
                    onPressed: () => _copySnippet(e.key, e.value),
                  ))
              .toList(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _jsResultController,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '执行结果',
            hintText: '将控制台输出粘贴到此处',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.clear, size: 18),
              label: const Text('清空结果'),
              onPressed: () => _jsResultController.clear(),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.paste, size: 18),
              label: const Text('粘贴'),
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
