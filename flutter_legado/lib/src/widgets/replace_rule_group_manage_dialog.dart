import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import 'confirm_dialog.dart';

/// 安卓端 AppPattern.splitGroupRegex：[,;，；]
final RegExp _splitGroupRegex = RegExp(r'[,;，；]');

/// 替换规则分组管理弹窗（对标原版 `ui/replace/GroupManageDialog`）
///
/// 实现策略对齐 [BookSourceGroupManageDialog]：
/// - 分组从各规则 `group` 字段推导；
/// - 重命名/删除经批量 `updateReplaceRule` 改写；
/// - 「添加分组」收拢无分组规则（对齐 `ReplaceRuleViewModel.addGroup`）；
/// - 返回 true 表示数据有变更，调用方需刷新列表。
class ReplaceRuleGroupManageDialog extends ConsumerStatefulWidget {
  final List<ReplaceRule> rules;

  const ReplaceRuleGroupManageDialog({super.key, required this.rules});

  @override
  ConsumerState<ReplaceRuleGroupManageDialog> createState() =>
      _ReplaceRuleGroupManageDialogState();
}

class _ReplaceRuleGroupManageDialogState
    extends ConsumerState<ReplaceRuleGroupManageDialog> {
  List<ReplaceRule> _rules = [];
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _rules = List.of(widget.rules);
  }

  List<String> _splitGroups(String? group) {
    if (group == null || group.isEmpty) return const [];
    return group
        .split(_splitGroupRegex)
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }

  List<String> get _groups {
    final set = <String>{};
    for (final r in _rules) {
      set.addAll(_splitGroups(r.group));
    }
    return set.toList();
  }

  Future<void> _upGroup(String oldGroup, String? newGroup) async {
    setState(() => _busy = true);
    try {
      final api = ref.read(bookApiProvider);
      for (var i = 0; i < _rules.length; i++) {
        final r = _rules[i];
        final groups = _splitGroups(r.group);
        if (!groups.contains(oldGroup)) continue;
        final updated = groups
            .map((g) => g == oldGroup ? newGroup : g)
            .whereType<String>()
            .where((g) => g.isNotEmpty)
            .toList();
        final next = r.copyWith(
          group: updated.isEmpty ? null : updated.join(','),
        );
        await api.updateReplaceRule(next);
        _rules[i] = next;
      }
      _changed = true;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    if (_groups.contains(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分组「$name」已存在')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final api = ref.read(bookApiProvider);
      var moved = 0;
      for (var i = 0; i < _rules.length; i++) {
        final r = _rules[i];
        if (_splitGroups(r.group).isNotEmpty) continue;
        final next = r.copyWith(group: name);
        await api.updateReplaceRule(next);
        _rules[i] = next;
        moved++;
      }
      _changed = true;
      if (mounted) {
        setState(() {});
        if (moved == 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有未分组的规则可归入该分组')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加分组失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(String group) async {
    final controller = TextEditingController(text: group);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == group || !mounted) {
      return;
    }
    if (_groups.contains(newName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分组「$newName」已存在')),
      );
      return;
    }
    await _upGroup(group, newName);
  }

  Future<void> _delete(String group) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除分组',
      content: '确定要删除分组「$group」吗？分组内规则将移出该分组。',
      confirmText: '删除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _upGroup(group, null);
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Expanded(child: Text('分组管理')),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Symbols.add_rounded),
            tooltip: '添加分组',
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : _addGroup,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: groups.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '暂无分组',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: groups.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
                itemBuilder: (context, index) {
                  final group = groups[index];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(group),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Symbols.edit_rounded, size: 20),
                          tooltip: '重命名',
                          visualDensity: VisualDensity.compact,
                          onPressed: _busy ? null : () => _rename(group),
                        ),
                        IconButton(
                          icon: Icon(
                            Symbols.delete_rounded,
                            size: 20,
                            color: scheme.error,
                          ),
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: _busy ? null : () => _delete(group),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
