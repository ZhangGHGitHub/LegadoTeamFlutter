import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/bookshelf_manage/bookshelf_manage_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
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
  /// 顶栏搜索框（对标原版 activity_arrange_book.xml 的 view_search）
  final _searchCtrl = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _filter = _searchCtrl.text.trim().toLowerCase());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(bookshelfManageNotifierProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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
    return Scaffold(
      appBar: AppBar(
        // 原版 TitleBar 内嵌 view_search：搜索框与菜单图标同行，无标题文字
        title: SizedBox(
          height: 36,
          child: TextField(
            controller: _searchCtrl,
            style: TextStyle(color: theme.colorScheme.onPrimary),
            decoration: InputDecoration(
              hintText: '搜索书名',
              hintStyle: TextStyle(
                color: theme.colorScheme.onPrimary.withValues(alpha: 0.7),
              ),
              filled: true,
              fillColor: theme.colorScheme.onPrimary.withValues(alpha: 0.15),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              prefixIcon: Icon(Icons.search,
                  size: 20,
                  color: theme.colorScheme.onPrimary.withValues(alpha: 0.7)),
              suffixIcon: _filter.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear,
                          size: 18,
                          color: theme.colorScheme.onPrimary
                              .withValues(alpha: 0.7)),
                      onPressed: () => _searchCtrl.clear(),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(35),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        actions: [
          // 原版溢出菜单 bookshelf_manage.xml
          PopupMenuButton<String>(
            onSelected: _handleMenu,
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'group_manage', child: Text('分组管理')),
              const PopupMenuItem(
                  value: 'export_all', child: Text('导出所有使用书源的书籍')),
              const PopupMenuItem(
                  value: 'open_by_title', child: Text('点击书名打开书籍信息')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: selectedCount > 0
          ? _buildActionBar(theme, state)
          : null,
      body: _buildBody(theme, state),
    );
  }

  /// 溢出菜单处理（对标原版 BookshelfManageActivity.onOptionsItemSelected）
  void _handleMenu(String value) {
    switch (value) {
      case 'group_manage':
        Navigator.pushNamed(context, AppRoutes.bookGroups);
        break;
      default:
        const names = {
          'export_all': '导出所有使用书源的书籍',
          'open_by_title': '点击书名打开书籍信息',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${names[value] ?? value}」后续版本支持')),
        );
    }
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
    // 顶栏搜索框：UI 层按书名过滤（对标原版 searchView 实时筛选）
    final books = _filter.isEmpty
        ? state.books
        : state.books
            .where((b) => b.name.toLowerCase().contains(_filter))
            .toList();
    if (books.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off,
        title: '无匹配书籍',
        subtitle: '试试其他关键词',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: books.length,
      itemBuilder: (context, index) => _buildItem(theme, state, books[index]),
    );
  }

  /// 列表项（对标原版 item_arrange_book.xml：checkbox + 书名 15sp +
  /// 作者/来源/分组 12sp + 删除按钮，无封面缩略图）
  Widget _buildItem(
    ThemeData theme,
    BookshelfManageState state,
    Book book,
  ) {
    final selected = state.selectedUrls.contains(book.bookUrl);
    final cs = theme.colorScheme;
    final infoStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      color: cs.onSurfaceVariant,
    );
    return InkWell(
      onTap: () => _notifier.toggleSelect(book.bookUrl),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (_) => _notifier.toggleSelect(book.bookUrl),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.name.isEmpty ? '未命名书籍' : book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: cs.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    book.author.isEmpty ? '未知作者' : book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: infoStyle,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '来源：${book.originName.isEmpty ? '本地' : book.originName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: infoStyle,
                  ),
                  Text(
                    '分组：${_groupNames(book)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: infoStyle,
                  ),
                ],
              ),
            ),
            // 删除按钮（对标原版 tv_delete）
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              onPressed: () => _confirmDeleteSingle(book),
            ),
          ],
        ),
      ),
    );
  }

  /// 分组显示名（book.group 为位掩码，解析书架分组列表）
  String _groupNames(Book book) {
    if (book.group == 0) return '未分组';
    final groups = ref.watch(bookshelfNotifierProvider).groups;
    final names = groups
        .where((g) => g.groupId > 0 && (book.group & g.groupId) != 0)
        .map((g) => g.groupName)
        .toList();
    return names.isEmpty ? '未分组' : names.join('，');
  }

  /// 单本删除（对标原版 item 内 tv_delete）
  Future<void> _confirmDeleteSingle(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要删除《${book.name}》吗？'),
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
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(bookApiProvider).deleteBook(book.bookUrl);
      await _notifier.load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  /// 底部多选操作条（对标原版 SelectActionBar：全选 + 已选数 + 批量操作）
  Widget _buildActionBar(ThemeData theme, BookshelfManageState state) {
    final colorScheme = theme.colorScheme;
    final allSelected =
        state.books.isNotEmpty && state.selectedUrls.length == state.books.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            // 全选复选框 + 已选数（对标 cbSelectedAll + tv_selected）
            Checkbox(
              value: allSelected,
              onChanged: (_) =>
                  allSelected ? _notifier.deselectAll() : _notifier.selectAll(),
            ),
            Text(
              '已选 ${state.selectedUrls.length} 本',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: colorScheme.error),
              onPressed: () => _confirmDelete(state),
              child: const Text('删除'),
            ),
            TextButton(
              onPressed: () => _showGroupPicker(state),
              child: const Text('分组'),
            ),
            TextButton(
              onPressed: _pinSelected,
              child: const Text('置顶'),
            ),
          ],
        ),
      ),
    );
  }
}
