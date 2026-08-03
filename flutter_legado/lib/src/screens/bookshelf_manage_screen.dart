import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/bookshelf_manage/bookshelf_manage_notifier.dart';
import '../providers/providers.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 书架管理页面
///
/// 对标安卓原版 BookshelfManageActivity：书籍多选，支持批量删除、
/// 移动到分组、置顶（REFACTORING_REMAINING_PLAN §4.3 P2-2 ③）。
class BookshelfManageScreen extends ConsumerStatefulWidget {
  const BookshelfManageScreen({super.key});

  @override
  ConsumerState<BookshelfManageScreen> createState() =>
      _BookshelfManageScreenState();
}

class _BookshelfManageScreenState extends ConsumerState<BookshelfManageScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(bookshelfManageNotifierProvider.notifier).load();
    });
  }

  BookshelfManageNotifier get _notifier =>
      ref.read(bookshelfManageNotifierProvider.notifier);

  Future<void> _confirmDelete(BookshelfManageState state) async {
    final count = state.selectedUrls.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要删除选中的 $count 本书吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _notifier.removeSelected();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('删除完成'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  Future<void> _showGroupPicker(BookshelfManageState state) async {
    List<BookGroup> groups;
    try {
      groups = await ref.read(bookApiProvider).getBookGroups();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取分组失败: $e')),
        );
      }
      return;
    }
    if (!mounted || groups.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无可用分组，请先在分组管理创建')),
        );
      }
      return;
    }
    if (!mounted) return;
    final groupId = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('移动到分组'),
        children: [
          for (final g in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, g.groupId),
              child: Text(g.groupName.isEmpty ? '未命名分组' : g.groupName),
            ),
        ],
      ),
    );
    if (groupId != null && mounted) {
      await _notifier.moveSelectedToGroup(groupId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已移动到分组'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  Future<void> _pinSelected() async {
    await _notifier.pinSelected();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已置顶'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(bookshelfManageNotifierProvider);
    final selectedCount = state.selectedUrls.length;
    final allSelected =
        state.books.isNotEmpty && selectedCount == state.books.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          selectedCount > 0 ? '已选择 $selectedCount 本' : '书架管理',
        ),
        actions: [
          TextButton(
            onPressed: state.books.isEmpty
                ? null
                : () => allSelected
                    ? _notifier.deselectAll()
                    : _notifier.selectAll(),
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
        ],
      ),
      bottomNavigationBar: selectedCount > 0
          ? _buildActionBar(theme, state)
          : null,
      body: _buildBody(theme, state),
    );
  }

  Widget _buildBody(ThemeData theme, BookshelfManageState state) {
    if (state.isLoading || state.isBusy) {
      return const LoadingIndicator();
    }
    if (state.error != null) {
      return ErrorView(
        message: state.error!,
        onRetry: () => _notifier.load(),
      );
    }
    if (state.books.isEmpty) {
      return const EmptyState(
        icon: Icons.library_books_outlined,
        title: '书架为空',
        subtitle: '请先在书架添加书籍',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: state.books.length,
      itemBuilder: (context, index) =>
          _buildItem(theme, state, state.books[index]),
    );
  }

  Widget _buildItem(
    ThemeData theme,
    BookshelfManageState state,
    Book book,
  ) {
    final selected = state.selectedUrls.contains(book.bookUrl);
    final coverUrl = book.customCoverUrl ?? book.coverUrl;
    return CheckboxListTile(
      value: selected,
      onChanged: (_) => _notifier.toggleSelect(book.bookUrl),
      secondary: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: (coverUrl != null && coverUrl.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: coverUrl,
                width: 42,
                height: 56,
                fit: BoxFit.cover,
                memCacheWidth: 84,
                errorWidget: (_, _, _) =>
                    const BookCover(width: 42, height: 56),
              )
            : const BookCover(width: 42, height: 56),
      ),
      title: Text(
        book.name.isEmpty ? '未命名书籍' : book.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        book.author.isEmpty ? '未知作者' : book.author,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildActionBar(ThemeData theme, BookshelfManageState state) {
    final colorScheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => _confirmDelete(state),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.folder_outlined),
                label: const Text('分组'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => _showGroupPicker(state),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.vertical_align_top),
                label: const Text('置顶'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _pinSelected,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
