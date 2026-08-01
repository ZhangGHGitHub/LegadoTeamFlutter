import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/reader_provider.dart';
import '../routes.dart';
import '../utils/responsive.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_grid_item.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

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
      // 安卓原版：纯居中灰字空状态
      return EmptyState(
        icon: Icons.library_books,
        title: AppStrings.emptyBookshelf,
        simple: true,
      );
    }

    return CustomRefreshIndicator(
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
    // 响应式网格：按可用宽度动态计算列数（手机 2 列 / 中大屏 3 列 / 平板 4 列）
    // 使用 SliverLayoutBuilder 而非 LayoutBuilder，因为父级是 CustomScrollView（需要 Sliver 子组件）
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = Responsive.gridColumnsForWidth(constraints.crossAxisExtent);
        final aspectRatio =
            Responsive.bookGridChildAspectRatio(constraints.crossAxisExtent);
        return SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: aspectRatio,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) {
              return _buildGridItem(context, books[index]);
            },
          ),
        );
      },
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
          // 安卓原版：长按直接打开书籍信息页
          onLongPress: () => _openBookInfo(context, book),
        );
      },
    );
  }

  Widget _buildGridItem(BuildContext context, Book book) {
    // 稳定 ValueKey（bookUrl）避免数据变化时整网格重建；RepaintBoundary 隔离重绘区域
    final item = BookGridItem(
      key: ValueKey(book.bookUrl),
      title: book.name,
      coverUrl: book.customCoverUrl ?? book.coverUrl,
      author: book.durChapterTitle ?? AppStrings.unread,
      onTap: () => _openBook(context, book),
      // 封面长按：打开书籍信息页（对齐安卓原版）
      onCoverLongPress: () => _openBookInfo(context, book),
      // 标题/信息区域长按：弹出操作菜单
      onInfoLongPress: () => _showBookActionSheet(context, book),
    );
    return RepaintBoundary(child: item);
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
    final readerProvider = context.read<ReaderProvider>();
    readerProvider.openBook(book);
    Navigator.pushNamed(context, AppRoutes.reader);
  }

  /// 长按封面直接打开书籍信息页（对齐安卓原版行为）
  void _openBookInfo(BuildContext context, Book book) {
    Navigator.pushNamed(
      context,
      AppRoutes.bookInfo,
      arguments: book,
    );
  }

  /// 分享书籍（对齐 Android 原版：书名 + 作者 + 来源）
  void _shareBook(Book book) {
    final buffer = StringBuffer('《${book.name}》');
    if (book.author.isNotEmpty) {
      buffer.write(' 作者：${book.author}');
    }
    if (book.bookUrl.isNotEmpty) {
      buffer.write('\n来源：${book.bookUrl}');
    }
    Share.share(buffer.toString());
  }

  /// 长按标题/信息区域弹出操作菜单（对齐安卓原版底部菜单）
  void _showBookActionSheet(BuildContext context, Book book) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 菜单标题：书名
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  book.name,
                  style: Theme.of(sheetContext).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('书籍信息'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openBookInfo(context, book);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  // TODO: 编辑书籍信息
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('分享'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _shareBook(book);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  '删除',
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmDeleteBook(context, book);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 确认删除书籍对话框
  void _confirmDeleteBook(BuildContext context, Book book) {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除书籍'),
          content: Text('确定要从书架中删除「${book.name}」吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                context.read<BookshelfProvider>().removeBook(book.bookUrl);
                messenger.showSnackBar(
                  SnackBar(content: Text('已删除「${book.name}」')),
                );
              },
              child: Text(
                '删除',
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.error,
                ),
              ),
            ),
          ],
        );
      },
    );
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
    }
  }
}
