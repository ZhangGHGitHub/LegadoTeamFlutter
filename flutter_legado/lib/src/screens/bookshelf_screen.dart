import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf_provider.dart';
import '../routes.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/confirm_dialog.dart';

/// 书架页面
class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  @override
  void initState() {
    super.initState();
    // 首次加载：下沉 loadSettings + loadBooks 到首帧回调
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<BookshelfProvider>().loadSettings();
        context.read<BookshelfProvider>().loadBooks();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context),
      body: _buildBody(context),
      floatingActionButton: _buildFab(context),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final provider = context.watch<BookshelfProvider>();
    return AppBar(
      title: Text(AppStrings.bookshelf),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: AppStrings.search,
          onPressed: () => Navigator.pushNamed(context, AppRoutes.search),
        ),
        IconButton(
          icon: Icon(provider.isGridView ? Icons.view_list : Icons.grid_view),
          tooltip: provider.isGridView ? AppStrings.listView : AppStrings.gridView,
          onPressed: () => provider.toggleViewMode(),
        ),
        PopupMenuButton<String>(
          onSelected: (value) => _handleMenuAction(context, value),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'update_all', child: Text(AppStrings.updateAll)),
            PopupMenuItem(value: 'import', child: Text(AppStrings.addLocalBook)),
            PopupMenuItem(value: 'groups', child: Text('分组管理')),
            PopupMenuItem(value: 'manage', child: Text(AppStrings.manageBookshelf)),
            PopupMenuItem(value: 'sources', child: Text(AppStrings.sourceManagement)),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'group_none',
              child: Row(
                children: [
                  Icon(provider.groupMode == GroupMode.none ? Icons.radio_button_checked : Icons.radio_button_off, size: 20),
                  const SizedBox(width: 8),
                  Text(AppStrings.groupByNoneLabel),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'group_source',
              child: Row(
                children: [
                  Icon(provider.groupMode == GroupMode.bySource ? Icons.radio_button_checked : Icons.radio_button_off, size: 20),
                  const SizedBox(width: 8),
                  Text(AppStrings.groupBySourceLabel),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'group_group',
              child: Row(
                children: [
                  Icon(provider.groupMode == GroupMode.byGroup ? Icons.radio_button_checked : Icons.radio_button_off, size: 20),
                  const SizedBox(width: 8),
                  Text(AppStrings.groupByGroupLabel),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final provider = context.watch<BookshelfProvider>();

    if (provider.loading && provider.books.isEmpty) {
      return LoadingIndicator(message: AppStrings.loadingBookshelf);
    }

    if (provider.error != null && provider.books.isEmpty) {
      return ErrorView(
        message: provider.error!,
        onRetry: () => provider.loadBooks(),
      );
    }

    if (provider.isEmpty) {
      return EmptyState(
        icon: Icons.library_books,
        title: AppStrings.emptyBookshelf,
        subtitle: AppStrings.emptyBookshelfHint,
        action: FilledButton.icon(
          onPressed: () => _addLocalBook(context),
          icon: const Icon(Icons.add),
          label: Text(AppStrings.addBook),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => provider.loadBooks(),
      child: CustomScrollView(
        slivers: [
          if (provider.showStats) _buildStatsSliver(context, provider),
          if (provider.showRecentReading) _buildRecentReadingSliver(context, provider),
          if (provider.isGridView)
            _buildGridSliver(context, provider.books)
          else
            _buildReorderableSliver(context, provider),
        ],
      ),
    );
  }

  Widget _buildStatsSliver(BuildContext context, BookshelfProvider provider) {
    final totalBooks = provider.books.length;
    final readingBooks = provider.books.where((b) => b.durChapterIndex > 0).length;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            _buildStatChip(context, AppStrings.allBooks, '$totalBooks', Icons.library_books),
            const SizedBox(width: 12),
            _buildStatChip(context, AppStrings.reading, '$readingBooks', Icons.menu_book),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(BuildContext context, String label, String value, IconData icon) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelSmall),
                Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSecondaryContainer,
                )),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentReadingSliver(BuildContext context, BookshelfProvider provider) {
    // 取最近阅读的书籍（有阅读进度的，按 durChapterTime 降序）
    final recentBooks = provider.books
        .where((b) => b.durChapterIndex > 0)
        .toList()
      ..sort((a, b) => b.durChapterTime.compareTo(a.durChapterTime));
    final show = recentBooks.take(3).toList();
    if (show.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              AppStrings.recentReading,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            height: 110,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: show.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final book = show[index];
                return _buildRecentBookCard(context, book);
              },
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildRecentBookCard(BuildContext context, Book book) {
    return GestureDetector(
      onTap: () => _openBook(context, book),
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              book.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              book.durChapterTitle ?? AppStrings.unknownChapter,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            if (book.totalChapterNum > 0)
              LinearProgressIndicator(
                value: book.totalChapterNum > 0
                    ? (book.durChapterIndex + 1) / book.totalChapterNum
                    : 0,
                minHeight: 3,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridSliver(BuildContext context, List<Book> books) {
    return SliverPadding(
      padding: const EdgeInsets.all(12),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        itemCount: books.length,
        itemBuilder: (context, index) {
          return _buildGridItem(context, books[index]);
        },
      ),
    );
  }

  Widget _buildReorderableSliver(BuildContext context, BookshelfProvider provider) {
    return SliverReorderableList(
      itemCount: provider.books.length,
      onReorder: (oldIndex, newIndex) => provider.reorderBook(oldIndex, newIndex),
      itemBuilder: (context, index) {
        final book = provider.books[index];
        return ListTile(
          key: ValueKey(book.bookUrl),
          leading: BookCover(
            coverUrl: book.customCoverUrl ?? book.coverUrl,
            width: 44,
            height: 60,
            borderRadius: 4,
          ),
          title: Text(
            book.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            book.durChapterTitle ?? AppStrings.unread,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: Text(
            book.totalChapterNum > 0
                ? '${book.durChapterIndex + 1}/${book.totalChapterNum}'
                : '',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          onTap: () => _openBook(context, book),
          onLongPress: () => _showBookMenu(context, book),
        );
      },
    );
  }

  Widget _buildGridItem(BuildContext context, Book book) {
    return GestureDetector(
      onTap: () => _openBook(context, book),
      onLongPress: () => _showBookMenu(context, book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: BookCover(
              coverUrl: book.customCoverUrl ?? book.coverUrl,
              width: double.infinity,
              height: double.infinity,
              borderRadius: 6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
          Text(
            book.durChapterTitle ?? AppStrings.unread,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildFab(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => _addLocalBook(context),
      tooltip: AppStrings.addLocalBook,
      child: const Icon(Icons.add),
    );
  }

  // ===== 操作 =====

  void _openBook(BuildContext context, Book book) {
    final readerProvider = context.read<dynamic>(); // ReaderProvider
    // ignore: avoid_dynamic_calls
    readerProvider.openBook(book);
    Navigator.pushNamed(context, AppRoutes.reader);
  }

  Future<void> _showBookMenu(BuildContext context, Book book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('查看详情'),
              onTap: () => Navigator.pop(ctx, 'info'),
            ),
            ListTile(
              leading: const Icon(Icons.vertical_align_top),
              title: Text(AppStrings.pinToTop),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(AppStrings.editInfo),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.folder),
              title: Text(AppStrings.group),
              onTap: () => Navigator.pop(ctx, 'group'),
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(ctx).colorScheme.error),
              title: Text(AppStrings.delete, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (action == null) return;

    if (action == 'info') {
      if (!context.mounted) return;
      Navigator.pushNamed(
        context,
        AppRoutes.bookInfo,
        arguments: book.bookUrl,
      );
      return;
    }

    if (action == 'delete') {
      if (!context.mounted) return;
      final confirmed = await showConfirmDialog(
        context,
        title: AppStrings.deleteBook,
        content: '${AppStrings.confirmDeleteBook}《${book.name}》?',
        confirmText: AppStrings.delete,
        isDestructive: true,
      );
      if (confirmed && context.mounted) {
        context.read<BookshelfProvider>().removeBook(book.bookUrl);
      }
    }
  }

  /// 选择本地书籍文件并导入书架
  Future<void> _addLocalBook(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final provider = context.read<BookshelfProvider>();
    final errorColor = Theme.of(context).colorScheme.error;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub', 'txt', 'mobi', 'pdf', 'umd'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    var successCount = 0;
    final failures = <String>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null) {
        failures.add(file.name);
        continue;
      }
      try {
        await provider.importLocalBook(path);
        successCount++;
      } catch (_) {
        failures.add(file.name);
      }
    }

    // 刷新书架，确保与后端数据一致
    await provider.loadBooks();

    final messages = <String>[];
    if (successCount > 0) messages.add('已导入 $successCount 本书籍');
    if (failures.isNotEmpty) {
      messages.add('${failures.length} 本导入失败：${failures.join('、')}');
    }
    if (messages.isEmpty) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(messages.join('；')),
        backgroundColor: successCount == 0 ? errorColor : null,
      ),
    );
  }

  void _handleMenuAction(BuildContext context, String action) {
    switch (action) {
      case 'update_all':
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.checkingUpdate)),
        );
        break;
      case 'import':
        Navigator.pushNamed(context, AppRoutes.importBooks);
        break;
      case 'groups':
        Navigator.pushNamed(context, AppRoutes.bookGroups);
        break;
      case 'manage':
        // 进入管理模式
        break;
      case 'sources':
        Navigator.pushNamed(context, AppRoutes.sources);
        break;
      case 'group_none':
        context.read<BookshelfProvider>().setGroupMode(GroupMode.none);
        break;
      case 'group_source':
        context.read<BookshelfProvider>().setGroupMode(GroupMode.bySource);
        break;
      case 'group_group':
        context.read<BookshelfProvider>().setGroupMode(GroupMode.byGroup);
        break;
    }
  }
}
