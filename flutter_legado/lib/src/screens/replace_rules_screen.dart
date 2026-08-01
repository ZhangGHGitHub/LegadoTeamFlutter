import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/replace_rule_provider.dart';

/// 替换规则管理页面
class ReplaceRulesScreen extends StatefulWidget {
  const ReplaceRulesScreen({super.key});

  @override
  State<ReplaceRulesScreen> createState() => _ReplaceRulesScreenState();
}

class _ReplaceRulesScreenState extends State<ReplaceRulesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ReplaceRuleProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('替换规则'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showRuleForm(context),
          ),
        ],
      ),
      body: Consumer<ReplaceRuleProvider>(
        builder: (context, provider, _) {
          if (provider.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (provider.error != null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(provider.error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => provider.load(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          if (provider.rules.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.find_replace,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text('暂无替换规则', style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  Text(
                    '点击右上角 + 添加规则',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          }
          return _buildRuleList(context, provider);
        },
      ),
    );
  }

  Widget _buildRuleList(BuildContext context, ReplaceRuleProvider provider) {
    return ReorderableListView.builder(
      itemCount: provider.rules.length,
      onReorder: (oldIndex, newIndex) {
        // 简单的排序处理
        if (oldIndex < newIndex) newIndex--;
        if (oldIndex < newIndex) {
          for (var i = oldIndex; i < newIndex; i++) {
            provider.moveDown(i);
          }
        } else {
          for (var i = oldIndex; i > newIndex; i--) {
            provider.moveUp(i);
          }
        }
      },
      itemBuilder: (context, index) {
        final rule = provider.rules[index];
        return _ReplaceRuleTile(
          key: ValueKey(rule.id),
          rule: rule,
          index: index,
          total: provider.rules.length,
          onToggle: (enabled) => provider.setEnabled(rule.id, enabled),
          onEdit: () => _showRuleForm(context, rule: rule),
          onDelete: () => _confirmDelete(context, provider, rule),
          onMoveUp: () => provider.moveUp(index),
          onMoveDown: () => provider.moveDown(index),
        );
      },
    );
  }

  void _showRuleForm(BuildContext context, {ReplaceRule? rule}) {
    final isEdit = rule != null;
    final nameCtrl = TextEditingController(text: rule?.name ?? '');
    final groupCtrl = TextEditingController(text: rule?.group ?? '');
    final patternCtrl = TextEditingController(text: rule?.pattern ?? '');
    final replacementCtrl = TextEditingController(
      text: rule?.replacement ?? '',
    );
    final scopeCtrl = TextEditingController(text: rule?.scope ?? '');
    final excludeScopeCtrl = TextEditingController(
      text: rule?.excludeScope ?? '',
    );
    final timeoutCtrl = TextEditingController(
      text: (rule?.timeoutMillisecond ?? 3000).toString(),
    );
    var isRegex = rule?.isRegex ?? true;
    var scopeTitle = rule?.scopeTitle ?? false;
    var scopeContent = rule?.scopeContent ?? true;
    var isEnabled = rule?.isEnabled ?? true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(isEdit ? '编辑替换规则' : '添加替换规则'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '规则名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: groupCtrl,
                  decoration: const InputDecoration(
                    labelText: '分组',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: patternCtrl,
                  decoration: const InputDecoration(
                    labelText: '匹配模式',
                    hintText: '正则表达式或文本',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('正则表达式'),
                  value: isRegex,
                  onChanged: (v) => setState(() => isRegex = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                TextField(
                  controller: replacementCtrl,
                  decoration: const InputDecoration(
                    labelText: '替换为',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('作用于标题'),
                  value: scopeTitle,
                  onChanged: (v) => setState(() => scopeTitle = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile(
                  title: const Text('作用于正文'),
                  value: scopeContent,
                  onChanged: (v) => setState(() => scopeContent = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                TextField(
                  controller: scopeCtrl,
                  decoration: const InputDecoration(
                    labelText: '作用范围',
                    hintText: '留空或 global 为全局，输入书名为特定书籍',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: excludeScopeCtrl,
                  decoration: const InputDecoration(
                    labelText: '排除范围',
                    hintText: '输入书名，多个用逗号分隔',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: timeoutCtrl,
                  decoration: const InputDecoration(
                    labelText: '超时时间（毫秒）',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('启用'),
                  value: isEnabled,
                  onChanged: (v) => setState(() => isEnabled = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final newRule = ReplaceRule(
                  id: rule?.id ?? 0,
                  name: nameCtrl.text,
                  group: groupCtrl.text.isEmpty ? null : groupCtrl.text,
                  pattern: patternCtrl.text,
                  replacement: replacementCtrl.text,
                  scope: scopeCtrl.text.isEmpty ? null : scopeCtrl.text,
                  scopeTitle: scopeTitle,
                  scopeContent: scopeContent,
                  excludeScope: excludeScopeCtrl.text.isEmpty
                      ? null
                      : excludeScopeCtrl.text,
                  isRegex: isRegex,
                  isEnabled: isEnabled,
                  timeoutMillisecond: int.tryParse(timeoutCtrl.text) ?? 3000,
                  order: rule?.order ?? 0,
                );
                final provider = context.read<ReplaceRuleProvider>();
                if (isEdit) {
                  provider.updateRule(newRule);
                } else {
                  provider.addRule(newRule);
                }
                Navigator.of(ctx).pop();
              },
              child: Text(isEdit ? '保存' : '添加'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    ReplaceRuleProvider provider,
    ReplaceRule rule,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${rule.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              provider.deleteRule(rule.id);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('规则已删除')));
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

class _ReplaceRuleTile extends StatelessWidget {
  final ReplaceRule rule;
  final int index;
  final int total;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  const _ReplaceRuleTile({
    super.key,
    required this.rule,
    required this.index,
    required this.total,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onEdit,
        onLongPress: onDelete,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // 排序手柄
              ReorderableDragStartListener(
                index: index,
                child: Icon(
                  Icons.drag_handle,
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(width: 8),
              // 规则信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name.isEmpty ? '(未命名)' : rule.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${rule.isRegex ? "正则" : "文本"}: ${rule.pattern} → ${rule.replacement}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (rule.scope != null && rule.scope!.isNotEmpty)
                      Text(
                        '范围: ${rule.scope}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                  ],
                ),
              ),
              // 启用开关
              Switch(value: rule.isEnabled, onChanged: onToggle),
            ],
          ),
        ),
      ),
    );
  }
}
