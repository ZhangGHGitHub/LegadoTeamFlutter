import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/txt_toc_rules/txt_toc_rules_notifier.dart';
import '../widgets/empty_state.dart';

/// TXT 目录规则管理页面
///
/// 管理用于识别 TXT 小说章节标题的正则规则，
/// 支持添加 / 编辑 / 删除、启用开关以及在线测试匹配效果。
///
/// 规则经 [TxtTocRulesNotifier] 持久化到 Rust 配置库（BookApi.getConfig/setConfig），
/// 不再使用内存态；「在线测试」仅为本地正则预览，不参与实际数据流。
class TxtTocRulesScreen extends ConsumerStatefulWidget {
  const TxtTocRulesScreen({super.key});

  @override
  ConsumerState<TxtTocRulesScreen> createState() => _TxtTocRulesScreenState();
}

class _TxtTocRulesScreenState extends ConsumerState<TxtTocRulesScreen> {
  static const _sampleText = '''第一章 初入江湖
少年站在山门前，望着云雾缭绕的主峰。
第2章 拜师学艺
他恭恭敬敬地递上了拜师帖。
1、命运的转折
一封突如其来的书信改变了一切。
Chapter 4 The Beginning
It was a dark and stormy night.''';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(txtTocRulesNotifierProvider.notifier).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(txtTocRulesNotifierProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TXT 目录规则'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: '导入默认',
            onPressed: () async {
              final n = await ref
                  .read(txtTocRulesNotifierProvider.notifier)
                  .importDefaultRules();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已导入 $n 条原版默认 TXT 目录规则')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加规则',
            onPressed: () => _showRuleForm(context),
          ),
        ],
      ),
      body: _buildBody(state),
    );
  }

  Widget _buildBody(TxtTocRulesState state) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.rules.isEmpty) {
      return const EmptyState(
        icon: Icons.format_list_numbered_rounded,
        title: '暂无目录规则',
        subtitle: '点击右上角 + 添加识别章节标题的正则规则',
      );
    }
    return _buildList(state);
  }

  Widget _buildList(TxtTocRulesState state) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.rules.length,
      itemBuilder: (context, index) {
        final rule = state.rules[index];
        return _RuleTile(
          rule: rule,
          onToggle: (v) =>
              ref.read(txtTocRulesNotifierProvider.notifier).setEnabled(rule.id, v),
          onEdit: () => _showRuleForm(context, rule: rule),
          onDelete: () => _confirmDelete(rule),
          onTest: () => _showTestDialog(rule),
        );
      },
    );
  }

  void _confirmDelete(TxtTocRule rule) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${rule.name.isEmpty ? '未命名' : rule.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(txtTocRulesNotifierProvider.notifier).deleteRule(rule.id);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('规则已删除'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showRuleForm(BuildContext context, {TxtTocRule? rule}) {
    final isEdit = rule != null;
    final nameCtrl = TextEditingController(text: rule?.name ?? '');
    final ruleCtrl = TextEditingController(text: rule?.rule ?? '');
    final replacementCtrl =
        TextEditingController(text: rule?.replacement ?? '');
    final exampleCtrl = TextEditingController(text: rule?.example ?? '');

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? '编辑规则' : '添加规则'),
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
                controller: ruleCtrl,
                decoration: const InputDecoration(
                  labelText: '正则表达式',
                  hintText: r'^第\s*\d+\s*章',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: replacementCtrl,
                decoration: const InputDecoration(
                  labelText: '替换为（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: exampleCtrl,
                decoration: const InputDecoration(
                  labelText: '示例文本（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (ruleCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('正则表达式不能为空')),
                );
                return;
              }
              final updated = TxtTocRule(
                id: rule?.id ?? 0,
                name: nameCtrl.text.trim(),
                rule: ruleCtrl.text,
                replacement: replacementCtrl.text,
                example: exampleCtrl.text.isEmpty ? null : exampleCtrl.text,
                serialNumber: rule?.serialNumber ?? 0,
                enable: rule?.enable ?? true,
              );
              final notifier = ref.read(txtTocRulesNotifierProvider.notifier);
              if (isEdit) {
                notifier.updateRule(updated);
              } else {
                notifier.addRule(updated);
              }
              Navigator.pop(ctx);
            },
            child: Text(isEdit ? '保存' : '添加'),
          ),
        ],
      ),
    );
  }

  void _showTestDialog(TxtTocRule rule) {
    final textCtrl = TextEditingController(
      text: (rule.example != null && rule.example!.isNotEmpty)
          ? rule.example!
          : _sampleText,
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final result = _runTest(rule.rule, textCtrl.text);
          return AlertDialog(
            title: Text('测试规则：${rule.name}'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: textCtrl,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '待匹配文本',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '匹配结果（${result.matches.length}）',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    width: double.maxFinite,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: result.error != null
                        ? Text(
                            '正则错误：${result.error}',
                            style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                          )
                        : result.matches.isEmpty
                            ? Text(
                                '无匹配项',
                                style: TextStyle(
                                  color: Theme.of(ctx).colorScheme.outline,
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: result.matches.length,
                                itemBuilder: (_, i) => Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 2),
                                  child: Text(
                                    '${i + 1}. ${result.matches[i]}',
                                  ),
                                ),
                              ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 本地正则预览（仅供用户测试规则，不参与实际 TXT 解析数据流）
  _TestResult _runTest(String pattern, String text) {
    try {
      final regex = RegExp(pattern, multiLine: true);
      final matches = regex
          .allMatches(text)
          .map((m) => m.group(0)?.trim() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      return _TestResult(matches: matches);
    } catch (e) {
      return _TestResult(matches: const [], error: e.toString());
    }
  }
}

/// 测试结果
class _TestResult {
  final List<String> matches;
  final String? error;

  const _TestResult({required this.matches, this.error});
}

/// 规则卡片
class _RuleTile extends StatelessWidget {
  final TxtTocRule rule;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  const _RuleTile({
    required this.rule,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          rule.name.isEmpty ? '(未命名)' : rule.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (!rule.enable) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '已禁用',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      rule.rule,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _actionChip(context, Icons.play_arrow_rounded, '测试',
                            onTest),
                        const SizedBox(width: 8),
                        _actionChip(context, Icons.delete_outline_rounded,
                            '删除', onDelete),
                      ],
                    ),
                  ],
                ),
              ),
              Switch(value: rule.enable, onChanged: onToggle),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionChip(
      BuildContext context, IconData icon, String label, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
