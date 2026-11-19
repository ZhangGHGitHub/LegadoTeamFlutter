import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/privacy/privacy_content_notifier.dart';
import '../providers/privacy/privacy_notifier.dart';
import '../providers/providers.dart';
import '../widgets/book_cover.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_indicator.dart';
import '../utils/error_message.dart';

/// 分组排序方式
enum _GroupSort { order, name, bookCount }

/// 书籍分组管理页面
///
/// 支持分组的增删改、排序、封面设置、显示/隐藏，以及将书籍分配到分组。
class BookGroupScreen extends ConsumerStatefulWidget {
  const BookGroupScreen({super.key});

  @override
  ConsumerState<BookGroupScreen> createState() => _BookGroupScreenState();
}

class _BookGroupScreenState extends ConsumerState<BookGroupScreen> {
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
      final api = ref.read(bookApiProvider);
      final groups = await api.getBookGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e);
        _loading = false;
      });
    }
  }

  /// 某分组内的书籍数量（2^n 位掩码 / 旧时间戳 exact 混合语义）
  int _bookCountOf(int groupId) {
    final books = ref.read(bookshelfNotifierProvider).books;
    return books.where((b) => bookBelongsToCustomGroup(b, groupId)).length;
  }

  List<BookGroup> get _sortedGroups {
    final list = [..._groups];
    switch (_sort) {
      case _GroupSort.order:
        list.sort((a, b) => a.order.compareTo(b.order));
      case _GroupSort.name:
        list.sort((a, b) => a.groupName.compareTo(b.groupName));
      case _GroupSort.bookCount:
        list.sort(
          (a, b) => _bookCountOf(b.groupId).compareTo(_bookCountOf(a.groupId)),
        );
    }
    return list;
  }

  // ===== 增删改 =====

  Future<void> _showEditDialog({BookGroup? group}) async {
    // 先等隐私策略/凭据就绪，避免首帧把「设为隐私分组」误置灰
    await ref.read(privacyNotifierProvider.notifier).ensureLoaded();
    if (!mounted) return;
    final isEdit = group != null;
    final nameController = TextEditingController(text: group?.groupName ?? '');
    final coverController = TextEditingController(text: group?.cover ?? '');
    // [批9c] 私密分组开关（对齐参考版 GroupEditSheet）：
    // 新建/普通分组可设；关闭已打开的开关需二次确认。
    // [批9c 回修 P2-3] 未设置隐私密码时置灰并提示，避免无凭据锁死分组。
    final hasPassword = ref.read(privacyNotifierProvider).hasPassword;
    var isPrivate = group?.isPrivate ?? false;
    final canSetPrivate = !isEdit || group.groupId > 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isEdit ? AppStrings.editGroup : AppStrings.newGroup),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(labelText: AppStrings.groupNameLabel),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: coverController,
                  decoration: InputDecoration(labelText: AppStrings.groupCoverUrlHint),
                ),
                if (canSetPrivate) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const ValueKey('group-private-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(AppStrings.setAsPrivateGroup),
                    subtitle: Text(
                      hasPassword
                          ? AppStrings.groupPrivateHint
                          : AppStrings.setPasswordInPrivacyFirst,
                      key: const ValueKey('group-private-hint'),
                    ),
                    value: isPrivate,
                    onChanged: !hasPassword
                        ? null
                        : (checked) async {
                            if (!checked && group?.isPrivate == true) {
                              final ok = await showConfirmDialog(
                                ctx,
                                title: AppStrings.disablePrivateGroup,
                                content: AppStrings.disablePrivateGroupHint,
                                confirmText: AppStrings.confirm,
                              );
                              if (!ok) return;
                            }
                            setDialogState(() => isPrivate = checked);
                          },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              key: const ValueKey('group-private-save'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.save),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;
    if (!mounted) return;

    final api = ref.read(bookApiProvider);
    try {
      if (isEdit) {
        await api.updateBookGroup(
          group.copyWith(
            groupName: name,
            cover: coverController.text.trim().isEmpty
                ? null
                : coverController.text.trim(),
          ),
        );
        // [批9c] updateBookGroup 不带 isPrivate（Rust 保留旧值），
        // 私密位单列落库；返回 false 说明分组行不存在，按失败处理。
        final hit = await api.setBookGroupPrivate(group.groupId, isPrivate);
        if (!hit) throw StateError('分组不存在，私密状态未保存');
      } else {
        final nextOrder = _groups.isEmpty
            ? 0
            : _groups.map((g) => g.order).reduce((a, b) => a > b ? a : b) + 1;
        final created = await api.addBookGroup(
          BookGroup(
            groupName: name,
            cover: coverController.text.trim().isEmpty
                ? null
                : coverController.text.trim(),
            order: nextOrder,
          ),
        );
        // [批9c] 新建分组固定非私密（Rust 语义），拿到 id 后再落私密位
        if (isPrivate) {
          final hit = await api.setBookGroupPrivate(created.groupId, true);
          if (!hit) throw StateError('分组已创建，但私密状态保存失败');
        }
      }
      // [批9c] 私密标记变更 → 书架派生过滤/锁定页同步
      await ref.read(privacyContentProvider.notifier).refresh();
      await ref.read(bookshelfNotifierProvider.notifier).refresh();
      await _loadGroups();
    } catch (e) {
      _showError(AppStrings.saveFailedWith(errorMessage(e)));
    }
  }

  Future<void> _deleteGroup(BookGroup group) async {
    final confirmed = await showConfirmDialog(
      context,
      title: AppStrings.deleteGroup,
      content: group.isPrivate
          ? AppStrings.groupConfirmDeletePrivate(group.groupName)
          : AppStrings.groupConfirmDelete(group.groupName),
      confirmText: AppStrings.delete,
      isDestructive: true,
    );
    if (!confirmed) return;
    if (!mounted) return;
    try {
      final api = ref.read(bookApiProvider);
      await api.deleteBookGroup(group.groupId);
      await _loadGroups();
      // [审查 P2-2] Rust 删除分组会同步清 books.group 位；刷新书架通知器，
      // 让书架列表/分组计数立即反映（不回退到已删除组）。
      await ref.read(bookshelfNotifierProvider.notifier).refresh();
    } catch (e) {
      _showError(AppStrings.deleteFailed(errorMessage(e)));
    }
  }

  Future<void> _toggleShow(BookGroup group) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.updateBookGroup(group.copyWith(show: !group.show));
      await _loadGroups();
    } catch (e) {
      _showError(AppStrings.groupUpdateFailed(errorMessage(e)));
    }
  }

  /// 拖拽排序后持久化 order
  Future<void> _persistOrder(List<BookGroup> reordered) async {
    setState(() => _groups = reordered);
    final api = ref.read(bookApiProvider);
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
      _showError(AppStrings.groupReorderFailed(errorMessage(e)));
      await _loadGroups();
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    // [LAYOUT_PLAN P3] 状态色走 tonal
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(color: cs.onErrorContainer)),
        backgroundColor: cs.errorContainer,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: Text(AppStrings.groupManageTitle),
        actions: [
          PopupMenuButton<_GroupSort>(
            tooltip: AppStrings.sortMethod,
            icon: const Icon(Symbols.sort_rounded),
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => [
              _sortItem(_GroupSort.order, AppStrings.groupSortByOrder),
              _sortItem(_GroupSort.name, AppStrings.sortByName),
              _sortItem(_GroupSort.bookCount, AppStrings.groupSortByBookCount),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        tooltip: AppStrings.newGroup,
        child: const Icon(Symbols.add_rounded),
      ),
    );
  }

  PopupMenuItem<_GroupSort> _sortItem(_GroupSort value, String label) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            _sort == value
                ? Symbols.radio_button_checked_rounded
                : Symbols.radio_button_unchecked_rounded,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return LoadingIndicator(message: AppStrings.groupLoading);
    if (_error != null) {
      return EmptyState(
        icon: Symbols.error_rounded,
        title: AppStrings.error,
        subtitle: _error,
        action: FilledButton(
          onPressed: _loadGroups,
          child: Text(AppStrings.retry),
        ),
      );
    }
    if (_groups.isEmpty) {
      return EmptyState(
        icon: Symbols.folder_special_rounded,
        title: AppStrings.groupEmpty,
        subtitle: AppStrings.groupEmptyHint,
      );
    }

    final groups = _sortedGroups;
    // 手动排序模式下支持拖拽
    if (_sort == _GroupSort.order) {
      return ReorderableListView.builder(
        // [LAYOUT_PLAN P3] 页面水平边距16dp
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
        itemCount: groups.length,
        onReorderItem: (oldIndex, newIndex) {
          final list = [...groups];
          final item = list.removeAt(oldIndex);
          list.insert(newIndex, item);
          _persistOrder(list);
        },
        itemBuilder: (context, index) =>
            _buildGroupTile(groups[index], draggable: true),
      );
    }
    return ListView.builder(
      // [LAYOUT_PLAN P3] 页面水平边距16dp
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      itemCount: groups.length,
      itemBuilder: (context, index) =>
          _buildGroupTile(groups[index], draggable: false),
    );
  }

  Widget _buildGroupTile(BookGroup group, {required bool draggable}) {
    final count = _bookCountOf(group.groupId);
    final privacy = ref.watch(privacyNotifierProvider);
    // 与书架 locked 同口径：仅“已启用 + 有密码 + 开启进入分组验证”时隐藏
    final hideCount =
        group.isPrivate &&
        privacy.hasPassword &&
        privacy.isGroupContentLocked(group.groupId, isPrivate: true);
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // [LAYOUT_PLAN P3] 分组卡圆角16dp + 组内行 vertical12/horizontal8 + 字级走 M3 Type Scale
    return Card(
      key: ValueKey(group.groupId),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        leading: draggable
            ? ReorderableDragStartListener(
                index: _sortedGroups.indexOf(group),
                child: BookCover(
                  coverUrl: group.cover,
                  bookName: group.groupName,
                  width: 40,
                  height: 54,
                  borderRadius: 4,
                  // [LAYOUT_PLAN P4] 补 heroTag（分组以 groupId 唯一，避免列表重复 tag）
                  heroTag: 'book-cover:group:${group.groupId}',
                ),
              )
            : BookCover(
                coverUrl: group.cover,
                bookName: group.groupName,
                width: 40,
                height: 54,
                borderRadius: 4,
                // [LAYOUT_PLAN P4] 补 heroTag（分组以 groupId 唯一，避免列表重复 tag）
                heroTag: 'book-cover:group:${group.groupId}',
              ),
        title: Text(
          group.groupName,
          // [LAYOUT_PLAN P3] 列表行字级走 M3 Type Scale
          style: textTheme.titleSmall?.copyWith(
            color: group.show ? null : cs.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          // [批9c 回修 P2-2] 私密组锁定口径下不展示书籍数（规模也是信息）
          hideCount ? '—' : AppStrings.groupBookCount(count),
          style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 显示/隐藏开关
            Tooltip(
              message: group.show
                  ? AppStrings.groupShowOnShelf
                  : AppStrings.groupHideOnShelf,
              child: Switch(
                value: group.show,
                onChanged: (_) => _toggleShow(group),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (action) => _handleAction(action, group),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'assign',
                  child: Text(AppStrings.assignBooks),
                ),
                PopupMenuItem(value: 'edit', child: Text(AppStrings.edit)),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    AppStrings.delete,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
    // 先等策略/标记就绪，否则首次读取会拿到 enabled=false 的默认态而漏脱敏
    await ref.read(privacyNotifierProvider.notifier).ensureLoaded();
    await ref.read(privacyContentProvider.notifier).ensureLoaded();
    if (!mounted) return;
    // [批9c 回修 P2-2] 分配列表剔除私密且未获准的书：书名/作者与勾选态
    // 都可能是身份/归属信息；已隐藏的书籍保持原分组不变。
    final privacy = ref.read(privacyNotifierProvider);
    final privacyContent = ref.read(privacyContentProvider);
    final allBooks = ref.read(bookshelfNotifierProvider).books;
    if (allBooks.isEmpty) {
      _showError(AppStrings.bookshelfEmptyNoBooks);
      return;
    }
    final books = allBooks
        .where((b) => !privacyContent.isBookLocked(b, privacy))
        .toList();
    final hiddenCount = allBooks.length - books.length;
    final selected = <String>{
      for (final b in books)
        if (bookBelongsToCustomGroup(b, group.groupId)) b.bookUrl,
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(AppStrings.groupAssignTitle(group.groupName)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hiddenCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      AppStrings.groupAssignHiddenHint(hiddenCount),
                      key: const ValueKey('group-assign-hidden-hint'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: books.length,
                    itemBuilder: (_, i) {
                      final book = books[i];
                      final checked = selected.contains(book.bookUrl);
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        title: Text(
                          book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    final api = ref.read(bookApiProvider);
    try {
      for (final book in books) {
        final shouldIn = selected.contains(book.bookUrl);
        final isIn = bookBelongsToCustomGroup(book, group.groupId);
        if (shouldIn && !isIn) {
          await api.setBookGroup(
            book.bookUrl,
            nextGroupMaskOnAssign(book, group.groupId),
          );
        } else if (!shouldIn && isIn) {
          await api.setBookGroup(
            book.bookUrl,
            nextGroupMaskOnRemove(book, group.groupId),
          );
        }
      }
      await ref.read(bookshelfNotifierProvider.notifier).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.groupAssignUpdated(group.groupName))),
        );
      }
    } catch (e) {
      _showError(AppStrings.groupAssignFailed(errorMessage(e)));
    }
  }
}
