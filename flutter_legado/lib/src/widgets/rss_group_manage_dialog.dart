import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import 'confirm_dialog.dart';

/// 安卓端 AppPattern.splitGroupRegex：[,;，；]
final RegExp _splitGroupRegex = RegExp(r'[,;，；]');

/// 订阅源分组管理弹窗（对标原版 GroupManageDialog）
///
/// 展示全部源推导出的分组列表，支持重命名与删除分组：
/// - 原版分组存独立分组表；Flutter FFI 无分组表 API，分组只能从各源
///   sourceGroup 推导，故重命名/删除通过批量更新源实现，
///   「新增空分组」无法持久化而不提供
/// - 返回 true 表示数据有变更，调用方需刷新列表
class RssGroupManageDialog extends ConsumerStatefulWidget {
  /// 当前全部订阅源（分组推导与批量更新的数据基础）
  final List<RssSource> sources;

  const RssGroupManageDialog({super.key, required this.sources});

  @override
  ConsumerState<RssGroupManageDialog> createState() =>
      _RssGroupManageDialogState();
}

class _RssGroupManageDialogState extends ConsumerState<RssGroupManageDialog> {
  List<RssSource> _sources = [];
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _sources = List.of(widget.sources);
  }

  List<String> _splitGroups(String? sourceGroup) {
    if (sourceGroup == null || sourceGroup.isEmpty) return const [];
    return sourceGroup
        .split(_splitGroupRegex)
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }

  /// 聚合分组（LinkedHashSet 保序）
  List<String> get _groups {
    final set = <String>{};
    for (final s in _sources) {
      set.addAll(_splitGroups(s.sourceGroup));
    }
    return set.toList();
  }

  /// 分组重命名/删除：批量更新含该分组的所有源
  /// （对标原版 viewModel.upGroup(oldGroup, newGroup)，null 表示删除）
  Future<void> _upGroup(String oldGroup, String? newGroup) async {
    setState(() => _busy = true);
    try {
      final api = ref.read(bookApiProvider);
      for (final s in _sources) {
        final groups = _splitGroups(s.sourceGroup);
        if (!groups.contains(oldGroup)) continue;
        final updated = groups
            .map((g) => g == oldGroup ? newGroup : g)
            .whereType<String>()
            .where((g) => g.isNotEmpty)
            .toList();
        final next =
            s.copyWith(sourceGroup: updated.isEmpty ? null : updated.join(','));
        await api.updateRssSource(next);
        // 同步本地副本，保证连续操作数据一致
        _sources[_sources.indexOf(s)] = next;
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

  /// 新增分组：把所有「无分组」的订阅源统一归入该分组名
  /// （对标原版 viewModel.addGroup：取 noGroup 源批量设置 sourceGroup，
  /// 原版并非创建空分组，而是收拢未分组源，故可经 updateRssSource 实现）
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
      for (final s in _sources) {
        // 仅收拢无分组的源（对标原版 rssSourceDao.noGroup）
        if (_splitGroups(s.sourceGroup).isNotEmpty) continue;
        final next = s.copyWith(sourceGroup: name);
        await api.updateRssSource(next);
        _sources[_sources.indexOf(s)] = next;
        moved++;
      }
      _changed = true;
      if (mounted) {
        setState(() {});
        if (moved == 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有未分组的订阅源可归入该分组')),
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
      content: '确定要删除分组「$group」吗？分组内订阅源将移出该分组。',
      confirmText: '删除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _upGroup(group, null);
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return AlertDialog(
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
          // 新增分组（对标原版 group_manage.xml menu_add）
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
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('暂无分组')),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: groups.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final group = groups[index];
                  return ListTile(
                    dense: true,
                    title: Text(group),
                    // 编辑（对标原版 tv_edit）
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Symbols.edit_rounded, size: 20),
                          tooltip: '重命名',
                          visualDensity: VisualDensity.compact,
                          onPressed: _busy ? null : () => _rename(group),
                        ),
                        // 删除（对标原版 tv_del）
                        IconButton(
                          icon: Icon(
                            Symbols.delete_rounded,
                            size: 20,
                            color: Theme.of(context).colorScheme.error,
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
