import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../bridge/rust_lib.dart' as bridge;
import '../models/models.dart';
import '../providers/providers.dart';

/// RSS 源编辑器页面
///
/// 支持新建/编辑 RSS 源，包含基本信息和规则配置。
class RssSourceEditScreen extends ConsumerStatefulWidget {
  /// 编辑模式时传入已有源，null 表示新建
  final RssSource? source;

  const RssSourceEditScreen({super.key, this.source});

  @override
  ConsumerState<RssSourceEditScreen> createState() => _RssSourceEditScreenState();
}

class _RssSourceEditScreenState extends ConsumerState<RssSourceEditScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  String? _testError;

  // 基本信息
  late TextEditingController _nameCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _iconCtrl;
  late TextEditingController _groupCtrl;
  late TextEditingController _commentCtrl;

  // 规则
  late TextEditingController _ruleArticlesCtrl;
  late TextEditingController _ruleTitleCtrl;
  late TextEditingController _ruleLinkCtrl;
  late TextEditingController _rulePubDateCtrl;
  late TextEditingController _ruleDescriptionCtrl;
  late TextEditingController _ruleImageCtrl;
  late TextEditingController _ruleContentCtrl;
  late TextEditingController _ruleNextPageCtrl;

  bool get _isEdit => widget.source != null;

  @override
  void initState() {
    super.initState();

    final s = widget.source;
    _nameCtrl = TextEditingController(text: s?.sourceName ?? '');
    _urlCtrl = TextEditingController(text: s?.sourceUrl ?? '');
    _iconCtrl = TextEditingController(text: s?.sourceIcon ?? '');
    _groupCtrl = TextEditingController(text: s?.sourceGroup ?? '');
    _commentCtrl = TextEditingController(text: s?.sourceComment ?? '');

    _ruleArticlesCtrl = TextEditingController(text: s?.ruleArticles ?? '');
    _ruleTitleCtrl = TextEditingController(text: s?.ruleTitle ?? '');
    _ruleLinkCtrl = TextEditingController(text: s?.ruleLink ?? '');
    _rulePubDateCtrl = TextEditingController(text: s?.rulePubDate ?? '');
    _ruleDescriptionCtrl =
        TextEditingController(text: s?.ruleDescription ?? '');
    _ruleImageCtrl = TextEditingController(text: s?.ruleImage ?? '');
    _ruleContentCtrl = TextEditingController(text: s?.ruleContent ?? '');
    _ruleNextPageCtrl = TextEditingController(text: s?.ruleNextPage ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _iconCtrl.dispose();
    _groupCtrl.dispose();
    _commentCtrl.dispose();
    _ruleArticlesCtrl.dispose();
    _ruleTitleCtrl.dispose();
    _ruleLinkCtrl.dispose();
    _rulePubDateCtrl.dispose();
    _ruleDescriptionCtrl.dispose();
    _ruleImageCtrl.dispose();
    _ruleContentCtrl.dispose();
    _ruleNextPageCtrl.dispose();
    super.dispose();
  }

  RssSource _buildSource() {
    return RssSource(
      sourceName: _nameCtrl.text.trim(),
      sourceUrl: _urlCtrl.text.trim(),
      sourceIcon: _iconCtrl.text.trim(),
      sourceGroup:
          _groupCtrl.text.trim().isNotEmpty ? _groupCtrl.text.trim() : null,
      sourceComment: _commentCtrl.text.trim().isNotEmpty
          ? _commentCtrl.text.trim()
          : null,
      enabled: widget.source?.enabled ?? true,
      ruleArticles: _ruleArticlesCtrl.text.trim().isNotEmpty
          ? _ruleArticlesCtrl.text.trim()
          : null,
      ruleTitle: _ruleTitleCtrl.text.trim().isNotEmpty
          ? _ruleTitleCtrl.text.trim()
          : null,
      ruleLink: _ruleLinkCtrl.text.trim().isNotEmpty
          ? _ruleLinkCtrl.text.trim()
          : null,
      rulePubDate: _rulePubDateCtrl.text.trim().isNotEmpty
          ? _rulePubDateCtrl.text.trim()
          : null,
      ruleDescription: _ruleDescriptionCtrl.text.trim().isNotEmpty
          ? _ruleDescriptionCtrl.text.trim()
          : null,
      ruleImage: _ruleImageCtrl.text.trim().isNotEmpty
          ? _ruleImageCtrl.text.trim()
          : null,
      ruleContent: _ruleContentCtrl.text.trim().isNotEmpty
          ? _ruleContentCtrl.text.trim()
          : null,
      ruleNextPage: _ruleNextPageCtrl.text.trim().isNotEmpty
          ? _ruleNextPageCtrl.text.trim()
          : null,
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);

    try {
      final api = ref.read(bookApiProvider);
      final source = _buildSource();

      if (_isEdit) {
        // 编辑模式：删除旧源再添加新源（FFI 无 rssUpdateSource）
        await api.deleteRssSource(widget.source!.sourceUrl);
      }
      await api.addRssSource(source);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isEdit ? 'RSS 源已更新' : 'RSS 源已添加')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _testError = '请先输入 RSS 地址');
      return;
    }

    setState(() {
      _testing = true;
      _testResult = null;
      _testError = null;
    });

    try {
      final json = await bridge.rssFetchArticles(sourceUrl: url);
      final articles = jsonDecode(json) as List;
      if (articles.isEmpty) {
        setState(() => _testResult = '连接成功，但未获取到文章（可能需要配置规则）');
      } else {
        final titles = articles
            .take(5)
            .map((e) => (e as Map<String, dynamic>)['title'] ?? '(无标题)')
            .join('\n');
        setState(() {
          _testResult = '成功获取 ${articles.length} 篇文章：\n$titles';
        });
      }
    } catch (e) {
      setState(() => _testError = '测试失败: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '编辑 RSS 源' : '新建 RSS 源'),
        actions: [
          TextButton.icon(
            onPressed: _testing ? null : _test,
            icon: _testing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.science, size: 18),
            label: const Text('测试'),
          ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save, size: 18),
            label: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // === 基本信息 ===
            _sectionHeader('基本信息'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '源名称 *',
                hintText: '例如：少数派',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入源名称' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'RSS 地址 *',
                hintText: 'https://example.com/feed',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return '请输入 RSS 地址';
                if (!v.trim().startsWith('http')) return '地址必须以 http(s) 开头';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _iconCtrl,
              decoration: const InputDecoration(
                labelText: '图标 URL',
                hintText: '可选',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _groupCtrl,
              decoration: const InputDecoration(
                labelText: '分组',
                hintText: '可选，例如：科技',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _commentCtrl,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '可选',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),

            const SizedBox(height: 24),

            // === 规则配置 ===
            _sectionHeader('规则配置'),
            const SizedBox(height: 8),
            _ruleField(_ruleArticlesCtrl, '文章列表规则', 'ruleArticles，如 item 或 //item'),
            _ruleField(_ruleTitleCtrl, '标题规则', 'ruleTitle，如 title'),
            _ruleField(_ruleLinkCtrl, '链接规则', 'ruleLink，如 link'),
            _ruleField(_rulePubDateCtrl, '日期规则', 'rulePubDate，如 pubDate'),
            _ruleField(_ruleDescriptionCtrl, '描述规则', 'ruleDescription'),
            _ruleField(_ruleImageCtrl, '图片规则', 'ruleImage'),
            _ruleField(_ruleContentCtrl, '内容规则', 'ruleContent'),
            _ruleField(_ruleNextPageCtrl, '下一页规则', 'ruleNextPage'),

            // === 测试结果 ===
            if (_testResult != null || _testError != null) ...[
              const SizedBox(height: 24),
              _sectionHeader('测试结果'),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _testError != null
                      ? Theme.of(context).colorScheme.errorContainer
                      : Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _testError ?? _testResult!,
                  style: TextStyle(
                    fontSize: 13,
                    color: _testError != null
                        ? Theme.of(context).colorScheme.onErrorContainer
                        : Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
    );
  }

  Widget _ruleField(
    TextEditingController ctrl,
    String label,
    String hint,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctrl,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}
