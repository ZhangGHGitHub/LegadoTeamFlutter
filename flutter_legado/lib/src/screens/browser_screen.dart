import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 内置浏览器页面
///
/// 当前构建未包含 webview_flutter（桌面端无 WebView 实现），
/// 采用 url_launcher 降级方案：内部维护导航历史栈（前进/后退/刷新），
/// 页面在系统浏览器中打开，并提供 JavaScript 片段提取助手
/// （生成常用提取脚本 → 复制到外部浏览器控制台执行 → 粘贴回结果）。
class BrowserScreen extends StatefulWidget {
  /// 初始 URL（可选）
  final String? initialUrl;

  const BrowserScreen({super.key, this.initialUrl});

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
    if (initial.isNotEmpty) {
      _urlController.text = initial;
      _navigate(initial);
    }
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
    if (!_canGoBack) return;
    setState(() => _currentIndex--);
    final url = _currentUrl;
    if (url != null) {
      _urlController.text = url;
      _openExternal(url);
    }
  }

  void _goForward() {
    if (!_canGoForward) return;
    setState(() => _currentIndex++);
    final url = _currentUrl;
    if (url != null) {
      _urlController.text = url;
      _openExternal(url);
    }
  }

  void _refresh() {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('内置浏览器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _currentUrl != null ? _refresh : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildAddressBar(theme),
          _buildToolbar(theme),
          const Divider(height: 1),
          Expanded(
            child: _currentUrl == null
                ? _buildEmpty(theme)
                : _buildContent(theme),
          ),
        ],
      ),
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
