import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf_provider.dart';
import '../services/book_api.dart';
import '../widgets/book_cover.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_indicator.dart';

/// 分组排序方式
enum _GroupSort { order, name, bookCount }

/// 书籍分组管理页面
///
/// 支持分组的增删改、排序、封面设置、显示/隐藏，以及将书籍分配到分组。
class BookGroupScreen extends StatefulWidget {
  const BookGroupScreen({super.key});

  @override
  State<BookGroupScreen> createState() => _BookGroupScreenState();
}

class _BookGroupScreenState extends State<BookGroupScreen> {
  List<BookGroup> _groups = [];
  bool _loading = true;
  String? _error;
  _GroupSort _sort = _GroupSort.order;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<BookApi>();
      final groups = await api.getBookGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 某分组内的书籍数量
  int _bookCountOf(int groupId) {
    final provider = context.read<BookshelfProvider>();
    return provider.books.where((b) => b.group == groupId).length;
  }

  List<BookGroup> get _sortedGroups {
    final list = [..._groups];
    switch (_sort) {
      case _GroupSort.order:
        list.sort((a, b) => a.order.compareTo(b.order));
      case _GroupSort.name:
        list.sort((a, b) => a.groupName.compareTo(b.groupName));
      case _GroupSort.bookCount:
        list.sort((a, b) => _bookCountOf(b.groupId).compareTo(_bookCountOf(a.groupId)));
    }
    return list;
  }

  // ===== 增删改 =====

  Future<void> _showEditDialog({BookGroup? group}) async {
    final isEdit = group != null;
    final nameController = TextEditingController(text: group?.groupName ?? '');
    final coverController = TextEditingController(text: group?.cover ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? '编辑分组' : '新建分组'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '分组名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: coverController,
                decoration: const InputDecoration(
                  labelText: '封面图片 URL（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.save),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;
    if (!mounted) return;

    final api = context.read<BookApi>();
    try {
      if (isEdit) {
        await api.updateBookGroup(group.copyWith(
          groupName: name,
          cover: coverController.text.trim().isEmpty ? null : coverController.text.trim(),
        ));
      } else {
        final nextOrder = _groups.isEmpty
            ? 0
            : _groups.map((g) => g.order).reduce((a, b) => a > b ? a : b) + 1;
        await api.addBookGroup(BookGroup(
          groupName: name,
          cover: coverController.text.trim().isEmpty ? null : coverController.text.trim(),
          order: nextOrder,
        ));
      }
      await _loadGroups();
    } catch (e) {
      _showError('保存失败：$e');
    }
  }

  Future<void> _deleteGroup(BookGroup group) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除分组',
      content: '确定要删除分组「${group.groupName}」吗？分组内的书籍不会被删除。',
      confirmText: AppStrings.delete,
      isDestructive: true,
    );
    if (!confirmed) return;
    if (!mounted) return;
    try {
      final api = context.read<BookApi>();
      await api.deleteBookGroup(group.groupId);
      await _loadGroups();
    } catch (e) {
      _showError('删除失败：$e');
    }
  }

  Future<void> _toggleShow(BookGroup group) async {
    try {
      final api = context.read<BookApi>();
      await api.updateBookGroup(group.copyWith(show: !group.show));
      await _loadGroups();
    } catch (e) {
      _showError('更新失败：$e');
    }
  }

  /// 拖拽排序后持久化 order
  Future<void> _persistOrder(List<BookGroup> reordered) async {
    setState(() => _groups = reordered);
    final api = context.read<BookApi>();
    try {
      for (var i = 0; i < reordered.length; i++) {
        final g = reordered[i];
        if (g.order != i) {
          final updated = g.copyWith(order: i);
          reordered[i] = updated;
          await api.updateBookGroup(updated);
        }
      }
      setState(() => _groups = [...reordered]);
    } catch (e) {
      _showError('排序失败：$e');
      await _loadGroups();
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分组管理'),
        actions: [
          PopupMenuButton<_GroupSort>(
            tooltip: '排序方式',
            icon: const Icon(Icons.sort),
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => [
              _sortItem(_GroupSort.order, '按排序值'),
              _sortItem(_GroupSort.name, '按名称'),
              _sortItem(_GroupSort.bookCount, '按书籍数量'),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        tooltip: '新建分组',
        child: const Icon(Icons.add),
      ),
    );
  }

  PopupMenuItem<_GroupSort> _sortItem(_GroupSort value, String label) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            _sort == value ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingIndicator(message: '加载分组...');
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: AppStrings.error,
        subtitle: _error,
        action: FilledButton(onPressed: _loadGroups, child: Text(AppStrings.retry)),
      );
    }
    if (_groups.isEmpty) {
      return EmptyState(
        icon: Icons.folder_special,
        title: '还没有分组',
        subtitle: '点击右下角按钮创建第一个分组',
      );
    }

    final groups = _sortedGroups;
    // 手动排序模式下支持拖拽
    if (_sort == _GroupSort.order) {
      return ReorderableListView.builder(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: groups.length,
        onReorder: (oldIndex, newIndex) {
          if (newIndex > oldIndex) newIndex--;
          final list = [...groups];
          final item = list.removeAt(oldIndex);
          list.insert(newIndex, item);
          _persistOrder(list);
        },
        itemBuilder: (context, index) => _buildGroupTile(groups[index], draggable: true),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: groups.length,
      itemBuilder: (context, index) => _buildGroupTile(groups[index], draggable: false),
    );
  }

  Widget _buildGroupTile(BookGroup group, {required bool draggable}) {
    final count = _bookCountOf(group.groupId);
    return Card(
      key: ValueKey(group.groupId),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: draggable
            ? ReorderableDragStartListener(
                index: _sortedGroups.indexOf(group),
                child: BookCover(
                  coverUrl: group.cover,
                  width: 40,
                  height: 54,
                  borderRadius: 4,
                ),
              )
            : BookCover(coverUrl: group.cover, width: 40, height: 54, borderRadius: 4),
        title: Text(
          group.groupName,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: group.show ? null : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text('$count 本书'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 显示/隐藏开关
            Tooltip(
              message: group.show ? '在书架显示' : '在书架隐藏',
              child: Switch(
                value: group.show,
                onChanged: (_) => _toggleShow(group),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (action) => _handleAction(action, group),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'assign', child: Text('分配书籍')),
                PopupMenuItem(value: 'edit', child: Text(AppStrings.edit)),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(AppStrings.delete,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              ],
            ),
          ],
        ),
        onTap: () => _assignBooks(group),
      ),
    );
  }

  void _handleAction(String action, BookGroup group) {
    switch (action) {
      case 'assign':
        _assignBooks(group);
      case 'edit':
        _showEditDialog(group: group);
      case 'delete':
        _deleteGroup(group);
    }
  }

  /// 将书籍分配到分组（多选）
  Future<void> _assignBooks(BookGroup group) async {
    final provider = context.read<BookshelfProvider>();
    if (provider.books.isEmpty) {
      _showError('书架暂无书籍');
      return;
    }
    final selected = <String>{
      for (final b in provider.books.where((b) => b.group == group.groupId)) b.bookUrl,
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('分配书籍到「${group.groupName}」'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: provider.books.length,
              itemBuilder: (_, i) {
                final book = provider.books[i];
                final checked = selected.contains(book.bookUrl);
                return CheckboxListTile(
                  dense: true,
                  value: checked,
                  title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(book.author, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onChanged: (on) {
                    setDialogState(() {
                      if (on == true) {
                        selected.add(book.bookUrl);
                      } else {
                        selected.remove(book.bookUrl);
                      }
                    });
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.save),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    final api = context.read<BookApi>();
    try {
      for (final book in provider.books) {
        final shouldIn = selected.contains(book.bookUrl);
        final isIn = book.group == group.groupId;
        if (shouldIn && !isIn) {
          await api.setBookGroup(book.bookUrl, group.groupId);
        } else if (!shouldIn && isIn) {
          await api.setBookGroup(book.bookUrl, 0);
        }
      }
      await provider.loadBooks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已更新「${group.groupName}」的书籍')),
        );
      }
    } catch (e) {
      _showError('分配失败：$e');
    }
  }
}
