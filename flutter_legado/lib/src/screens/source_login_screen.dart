import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 书源登录页面
///
/// 支持两种登录方式：
/// 1. WebView 登录（通过外部浏览器打开登录链接，再回填 Cookie）
/// 2. 手动 Cookie 输入
class SourceLoginScreen extends StatefulWidget {
  /// 书源 URL
  final String sourceUrl;

  /// 书源名称
  final String sourceName;

  /// 登录链接（可由书源 loginUrl 字段提供）
  final String? loginUrl;

  const SourceLoginScreen({
    super.key,
    required this.sourceUrl,
    required this.sourceName,
    this.loginUrl,
  });

  @override
  State<SourceLoginScreen> createState() => _SourceLoginScreenState();
}

class _SourceLoginScreenState extends State<SourceLoginScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // 手动 Cookie 输入控制器
  final _cookieNameCtrl = TextEditingController();
  final _cookieValueCtrl = TextEditingController();
  final _headerNameCtrl = TextEditingController();
  final _headerValueCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  // 已添加的 Cookie / Header 列表
  final List<MapEntry<String, String>> _cookies = [];
  final List<MapEntry<String, String>> _headers = [];

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _cookieNameCtrl.dispose();
    _cookieValueCtrl.dispose();
    _headerNameCtrl.dispose();
    _headerValueCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _openLoginUrl() async {
    final url = widget.loginUrl;
    if (url == null || url.isEmpty) {
      _showSnack('该书源未配置登录链接');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      _showSnack('登录链接无效');
      return;
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _showSnack('无法打开登录链接');
    }
  }

  void _addCookie() {
    final name = _cookieNameCtrl.text.trim();
    final value = _cookieValueCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Cookie 名称不能为空');
      return;
    }
    setState(() {
      _cookies.add(MapEntry(name, value));
      _cookieNameCtrl.clear();
      _cookieValueCtrl.clear();
    });
  }

  void _addHeader() {
    final name = _headerNameCtrl.text.trim();
    final value = _headerValueCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Header 名称不能为空');
      return;
    }
    setState(() {
      _headers.add(MapEntry(name, value));
      _headerNameCtrl.clear();
      _headerValueCtrl.clear();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // TODO: 调用 Rust 端保存登录信息（source_login 模块集成后接入）
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (mounted) {
        _showSnack('登录信息已保存');
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _clear() {
    setState(() {
      _cookies.clear();
      _headers.clear();
      _tokenCtrl.clear();
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('登录 - ${widget.sourceName}'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '手动输入'),
            Tab(text: '登录链接'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: _clear,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildManualTab(),
          _buildLoginUrlTab(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('保存登录信息'),
          ),
        ),
      ),
    );
  }

  Widget _buildManualTab() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Token（可选）', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _tokenCtrl,
          decoration: const InputDecoration(
            hintText: 'Bearer Token / API Key',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        Text('Cookies', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _buildKeyValueRow(
          nameCtrl: _cookieNameCtrl,
          valueCtrl: _cookieValueCtrl,
          nameHint: 'name',
          valueHint: 'value',
          onAdd: _addCookie,
        ),
        ..._cookies.map(
          (e) => ListTile(
            dense: true,
            title: Text('${e.key} = ${e.value}'),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _cookies.remove(e)),
            ),
          ),
        ),
        const Divider(height: 32),
        Text('Headers（可选）', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _buildKeyValueRow(
          nameCtrl: _headerNameCtrl,
          valueCtrl: _headerValueCtrl,
          nameHint: 'header name',
          valueHint: 'header value',
          onAdd: _addHeader,
        ),
        ..._headers.map(
          (e) => ListTile(
            dense: true,
            title: Text('${e.key}: ${e.value}'),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _headers.remove(e)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyValueRow({
    required TextEditingController nameCtrl,
    required TextEditingController valueCtrl,
    required String nameHint,
    required String valueHint,
    required VoidCallback onAdd,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: TextField(
            controller: nameCtrl,
            decoration: InputDecoration(
              hintText: nameHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextField(
            controller: valueCtrl,
            decoration: InputDecoration(
              hintText: valueHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          icon: const Icon(Icons.add),
          onPressed: onAdd,
        ),
      ],
    );
  }

  Widget _buildLoginUrlTab() {
    final theme = Theme.of(context);
    final url = widget.loginUrl;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.open_in_browser, size: 64),
            const SizedBox(height: 16),
            Text(
              url == null || url.isEmpty ? '该书源未配置登录链接' : url,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openLoginUrl,
              icon: const Icon(Icons.launch),
              label: const Text('在浏览器中打开'),
            ),
            const SizedBox(height: 12),
            Text(
              '在浏览器完成登录后，复制 Cookie 并切换到「手动输入」标签页粘贴。',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
