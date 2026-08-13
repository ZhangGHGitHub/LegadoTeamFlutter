import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';

/// 朗读引擎配置页面
///
/// 管理 HTTP TTS 朗读引擎：列表展示、新增、编辑、删除。
class ReadAloudConfigScreen extends ConsumerStatefulWidget {
  const ReadAloudConfigScreen({super.key});

  @override
  ConsumerState<ReadAloudConfigScreen> createState() => _ReadAloudConfigScreenState();
}

class _ReadAloudConfigScreenState extends ConsumerState<ReadAloudConfigScreen> {
  List<HttpTts> _engines = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEngines();
  }

  Future<void> _loadEngines() async {
    setState(() => _loading = true);
    try {
      final api = ref.read(bookApiProvider);
      final list = await api.getHttpTts();
      setState(() {
        _engines = list;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载朗读引擎失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteEngine(HttpTts engine) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(bookApiProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除朗读引擎'),
        content: Text('确定要删除「${engine.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await api.deleteHttpTts(engine.id);
      await _loadEngines();
      messenger.showSnackBar(
        const SnackBar(content: Text('已删除')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }

  Future<void> _addOrEditEngine([HttpTts? existing]) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(bookApiProvider);

    final result = await showDialog<HttpTts>(
      context: context,
      builder: (ctx) => _TtsEditDialog(engine: existing),
    );

    if (result == null) return;

    try {
      if (existing != null) {
        // 编辑：先删后加
        await api.deleteHttpTts(existing.id);
      }
      await api.addHttpTts(result);
      await _loadEngines();
      messenger.showSnackBar(
        SnackBar(content: Text(existing != null ? '已更新' : '已添加')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('朗读引擎'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadEngines,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEditEngine(),
        icon: const Icon(Icons.add),
        label: const Text('添加引擎'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _engines.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.record_voice_over_outlined,
                          size: 64, color: theme.colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(
                        '暂无朗读引擎',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '点击右下角按钮添加 HTTP TTS 引擎',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _engines.length,
                  itemBuilder: (context, index) {
                    final engine = _engines[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Icon(Icons.record_voice_over,
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                        title: Text(engine.name),
                        subtitle: Text(
                          engine.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              tooltip: '编辑',
                              onPressed: () => _addOrEditEngine(engine),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline,
                                  size: 20, color: theme.colorScheme.error),
                              tooltip: '删除',
                              onPressed: () => _deleteEngine(engine),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// TTS 引擎编辑对话框
class _TtsEditDialog extends StatefulWidget {
  final HttpTts? engine;

  const _TtsEditDialog({this.engine});

  @override
  State<_TtsEditDialog> createState() => _TtsEditDialogState();
}

class _TtsEditDialogState extends State<_TtsEditDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _headerCtrl;
  late TextEditingController _contentTypeCtrl;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final e = widget.engine;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _urlCtrl = TextEditingController(text: e?.url ?? '');
    _headerCtrl = TextEditingController(text: e?.header ?? '');
    _contentTypeCtrl = TextEditingController(text: e?.contentType ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _headerCtrl.dispose();
    _contentTypeCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final tts = HttpTts(
      id: widget.engine?.id ?? 0,
      name: _nameCtrl.text.trim(),
      url: _urlCtrl.text.trim(),
      header: _headerCtrl.text.trim().isNotEmpty ? _headerCtrl.text.trim() : null,
      contentType: _contentTypeCtrl.text.trim().isNotEmpty
          ? _contentTypeCtrl.text.trim()
          : null,
    );

    Navigator.pop(context, tts);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.engine != null ? '编辑朗读引擎' : '添加朗读引擎'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '名称 *',
                  hintText: '例如：Edge TTS',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'URL *',
                  hintText: 'http://localhost:1234/tts?text={{text}}',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入 URL';
                  if (!v.trim().startsWith('http')) return 'URL 必须以 http(s) 开头';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _contentTypeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Content-Type',
                  hintText: '可选，例如 audio/mpeg',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _headerCtrl,
                decoration: const InputDecoration(
                  labelText: '请求头 (JSON)',
                  hintText: '可选，例如 {"Authorization":"Bearer xxx"}',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
