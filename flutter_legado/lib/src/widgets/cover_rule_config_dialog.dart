// 封面规则配置对话框（设置批6b-1 自外观页迁出）
//
// 契约 §2.4 F4；对齐参考版 `CoverRuleConfigDialog`：搜索 URL + 封面提取
// 规则 + 启用开关 + 按书名测试搜索 + 候选预览/复制。原实现为
// `theme_config_screen.dart` 私有类，随「封面设置」入口迁至独立页后
// 抽为公共 Widget（行为不变）。
//
// 编写：全栈工程师（设置批6b-1） ｜ 2026-11-06
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../bridge/ffi.dart';

/// 封面规则配置对话框
class CoverRuleConfigDialog extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() loadRule;
  final Future<bool> Function(Map<String, dynamic> rule) saveRule;
  final Future<bool> Function() deleteRule;
  final Future<List<String>> Function(String name) onSearch;

  const CoverRuleConfigDialog({
    super.key,
    required this.loadRule,
    required this.saveRule,
    required this.deleteRule,
    required this.onSearch,
  });

  @override
  State<CoverRuleConfigDialog> createState() => _CoverRuleConfigDialogState();
}

class _CoverRuleConfigDialogState extends State<CoverRuleConfigDialog> {
  late final TextEditingController _searchUrlController =
      TextEditingController();
  late final TextEditingController _coverRuleController =
      TextEditingController();
  late final TextEditingController _nameController = TextEditingController();
  bool _enable = true;
  bool _loading = true;
  bool _saving = false;
  bool _searching = false;
  bool _searched = false;
  String? _error;
  List<String> _results = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchUrlController.dispose();
    _coverRuleController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  String _errMsg(Object e) => e is BridgeError ? e.message : e.toString();

  Future<void> _load() async {
    try {
      final rule = await widget.loadRule();
      if (!mounted) return;
      setState(() {
        _enable = rule['enable'] == true || rule['enable'] == 1;
        _searchUrlController.text = '${rule['searchUrl'] ?? ''}';
        _coverRuleController.text = '${rule['coverRule'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      debugPrint('CoverRuleConfig 加载失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '加载失败: ${_errMsg(e)}';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final searchUrl = _searchUrlController.text.trim();
    final coverRule = _coverRuleController.text.trim();
    if (searchUrl.isEmpty || coverRule.isEmpty) {
      setState(() => _error = '搜索url和cover规则不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.saveRule({
        'enable': _enable,
        'searchUrl': searchUrl,
        'coverRule': coverRule,
      });
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '保存失败: ${_errMsg(e)}';
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.deleteRule();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '删除失败: ${_errMsg(e)}';
        _saving = false;
      });
    }
  }

  Future<void> _search() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入书名');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final list = await widget.onSearch(name);
      if (!mounted) return;
      setState(() {
        _results = list;
        _searched = true;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败: ${_errMsg(e)}';
        _results = [];
        _searched = true;
        _searching = false;
      });
    }
  }

  void _preview(String url) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('封面预览'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Padding(
              padding: EdgeInsets.all(16),
              child: Text('图片加载失败'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _copy(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('封面 URL 已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('封面规则'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用'),
                      value: _enable,
                      onChanged: _saving
                          ? null
                          : (v) => setState(() => _enable = v),
                    ),
                    TextField(
                      controller: _searchUrlController,
                      decoration: const InputDecoration(
                        labelText: '搜索 URL',
                        hintText: '支持 {{key}} 模板',
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _coverRuleController,
                      decoration: const InputDecoration(labelText: '封面提取规则'),
                      minLines: 2,
                      maxLines: 6,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '按书名测试',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(hintText: '输入书名'),
                            onSubmitted: (_) => _search(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _searching || _saving ? null : _search,
                          child: const Text('测试'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_searching)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      )
                    else if (_searched && _results.isEmpty)
                      const Text(
                        '未搜到候选封面（无启用规则或全部失败）',
                        style: TextStyle(fontSize: 13),
                      )
                    else if (_results.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _results.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final url = _results[i];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Symbols.image_rounded,
                                      size: 18,
                                    ),
                                    tooltip: '预览',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _preview(url),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Symbols.content_copy_rounded,
                                      size: 18,
                                    ),
                                    tooltip: '复制',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _copy(url),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _delete,
          child: Text(
            '删除',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确定'),
        ),
      ],
    );
  }
}

/// 打开封面规则配置对话框（复用 BookApi 接口）
Future<void> showCoverRuleConfigDialog(
  BuildContext context, {
  required Future<Map<String, dynamic>> Function() loadRule,
  required Future<bool> Function(Map<String, dynamic> rule) saveRule,
  required Future<bool> Function() deleteRule,
  required Future<List<String>> Function(String name) onSearch,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => CoverRuleConfigDialog(
      loadRule: loadRule,
      saveRule: saveRule,
      deleteRule: deleteRule,
      onSearch: onSearch,
    ),
  );
}
