import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'confirm_dialog.dart';

/// 安卓端 AppPattern.splitGroupRegex：[,;，；]
final RegExp _splitGroupRegex = RegExp(r'[,;，；]');

/// 分组管理对话框统一壳（泛型）
///
/// 收敛三处同型重复实现（书源/替换规则/RSS 订阅源分组管理，原各自
/// 283-295 行、结构逐行同型；见 GLOBAL_COMPONENTS_UNIFY_SURVEY_20260930
/// B2 批）为单一参数化实现；三域差异仅四项：条目类型、分组字段读写、
/// 持久化回调、文案名词。
///
/// 实现策略（对齐原版 `ui/book/source/manage/GroupManageDialog` 系列）：
/// - Flutter FFI 无独立分组表，分组从各条目的分组字段推导（[,;，；] 分隔）；
/// - 重命名/删除通过批量持久化改写各条目分组字段；
/// - 「添加分组」收拢未分组条目（对标原版 `viewModel.addGroup` / noGroup）；
/// - 返回 true 表示数据有变更，调用方需刷新列表。
///
/// 本壳不依赖 riverpod：持久化经 [update] 回调注入（薄包装层接各域 API），
/// 便于无 Provider 环境测试。
class GroupManageDialog<T> extends StatefulWidget {
  /// 文案名词（书源 / 规则 / 订阅源），用于提示语：「没有未分组的{noun}可归入该分组」
  final String itemNoun;

  /// 当前全部条目（分组推导与批量更新的数据基础）
  final List<T> items;

  /// 读取条目的分组字段
  final String? Function(T item) groupOf;

  /// 写入条目的分组字段（null 表示移出分组）
  final T Function(T item, String? newGroup) copyWithGroup;

  /// 持久化单条目（各域 API：updateBookSource / updateReplaceRule / updateRssSource）
  final Future<void> Function(T item) update;

  const GroupManageDialog({
    super.key,
    required this.itemNoun,
    required this.items,
    required this.groupOf,
    required this.copyWithGroup,
    required this.update,
  });

  @override
  State<GroupManageDialog<T>> createState() => _GroupManageDialogState<T>();
}

class _GroupManageDialogState<T> extends State<GroupManageDialog<T>> {
  late final List<T> _items = List.of(widget.items);
  bool _busy = false;
  bool _changed = false;

  List<String> _splitGroups(String? group) {
    if (group == null || group.isEmpty) return const [];
    return group
        .split(_splitGroupRegex)
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }

  /// 聚合分组（LinkedHashSet 保序）
  List<String> get _groups {
    final set = <String>{};
    for (final item in _items) {
      set.addAll(_splitGroups(widget.groupOf(item)));
    }
    return set.toList();
  }

  /// 分组重命名/删除：批量更新含该分组的所有条目
  /// （对标原版 viewModel.upGroup(oldGroup, newGroup)，null 表示删除）
  Future<void> _upGroup(String oldGroup, String? newGroup) async {
    setState(() => _busy = true);
    try {
      for (final item in _items) {
        final groups = _splitGroups(widget.groupOf(item));
        if (!groups.contains(oldGroup)) continue;
        final updated = groups
            .map((g) => g == oldGroup ? newGroup : g)
            .whereType<String>()
            .where((g) => g.isNotEmpty)
            .toList();
        final next = widget.copyWithGroup(item, updated.isEmpty ? null : updated.join(','));
        await widget.update(next);
        _items[_items.indexOf(item)] = next;
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

  /// 新增分组：把所有「无分组」条目统一归入该分组名
  Future<void> _addGroup() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TextInputDialog(
        title: '添加分组',
        hintText: '分组名称',
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    if (_groups.contains(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分组「$name」已存在')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      var moved = 0;
      for (final item in _items) {
        if (_splitGroups(widget.groupOf(item)).isNotEmpty) continue;
        final next = widget.copyWithGroup(item, name);
        await widget.update(next);
        _items[_items.indexOf(item)] = next;
        moved++;
      }
      _changed = true;
      if (mounted) {
        setState(() {});
        if (moved == 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('没有未分组的${widget.itemNoun}可归入该分组')),
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
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(
        title: '重命名分组',
        hintText: '输入新分组名称',
        initialText: group,
      ),
    );
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
      content: '确定要删除分组「$group」吗？分组内${widget.itemNoun}将移出该分组。',
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
    // iOS 风格：大圆角、轻量标题行、列表靠间距而非硬边框
    return AlertDialog(
      // [LAYOUT_PLAN P2] 分组卡圆角统一 16dp（全局标尺）
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
                    // [LAYOUT_PLAN P2] 组内行 vertical12/horizontal8（全局行规范）
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 8,
                    ),
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

/// 分组名输入对话框（添加/重命名共用）
///
/// [B2 修复] controller 由本 State 持有：`await showDialog` 返回时退场动画
/// 尚未结束、TextField 仍在树上，旧实现在 await 返回后立即 dispose
/// controller 会触发「used after being disposed」（三域旧实现共有的
/// 未测隐患）；State.dispose 在退场动画完成后才被调用，彻底消除竞态。
class _TextInputDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final String initialText;

  const _TextInputDialog({
    required this.title,
    required this.hintText,
    this.initialText = '',
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hintText),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
