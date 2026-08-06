import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../utils/book_progress_utils.dart';
import '../utils/responsive.dart';
import '../utils/share_utils.dart';
import '../widgets/book_grid_item.dart';
import '../widgets/book_list_item.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 书架页面（Riverpod ConsumerStatefulWidget）
///
/// 状态由 [BookshelfNotifier] 管理，Widget 层仅负责渲染与交互。
/// Notifier 在 build() 时自动加载数据，无需 initState。
/// 多分组时顶栏显示分组 TabBar（对标原版 fragment_bookshelf1.xml TabLayout）。
class BookshelfScreen extends ConsumerStatefulWidget {
  /// 回滚顶部信号（主页双击底栏书架项时自增，对标原版 gotoTop）
  final ValueNotifier<int>? scrollTopSignal;

  const BookshelfScreen({super.key, this.scrollTopSignal});

  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends ConsumerState<BookshelfScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  int _tabControllerLen = 0;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.scrollTopSignal?.addListener(_onScrollTopSignal);
  }

  @override
  void dispose() {
    widget.scrollTopSignal?.removeListener(_onScrollTopSignal);
    _scrollController.dispose();
    _tabController?.removeListener(_onTabControllerChanged);
    _tabController?.dispose();
    super.dispose();
  }

  /// 双击底栏书架项 → 列表回滚顶部（对标 BaseBookshelfFragment.gotoTop）
  void _onScrollTopSignal() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 按分组数量维护 TabController（分组数变化时重建）。
  /// 不在 build 期间同步 index（会被 TabBar 内部状态覆盖），
  /// 改由 [_onTabControllerChanged] 在帧后回调中对齐。
  TabController _ensureTabController(int length) {
    if (_tabController == null || _tabControllerLen != length) {
      _tabController?.removeListener(_onTabControllerChanged);
      _tabController?.dispose();
      _tabController = TabController(length: length, vsync: this);
      _tabController!.addListener(_onTabControllerChanged);
      _tabControllerLen = length;
    }
    return _tabController!;
  }

  /// TabController 变化 → 持久化选中分组（对标原版 onTabSelected）
  void _onTabControllerChanged() {
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    final state = ref.read(bookshelfNotifierProvider);
    if (controller.index != state.selectedGroupIndex) {
      ref.read(bookshelfNotifierProvider.notifier).selectGroup(controller.index);
    }
  }

  /// 状态选中分组 → 帧后同步到 TabController（避免 build 期间改动）
  void _syncTabControllerIndex(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _tabController;
      if (!mounted || controller == null) return;
      if (controller.index != index && index < controller.length) {
        controller.animateTo(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 安卓原版书架页无 FAB：添加书籍入口在顶栏溢出菜单
    return Scaffold(
      appBar: _buildAppBar(context, ref),
      body: _buildBody(context, ref),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookshelfNotifierProvider);
    // 对标原版 BookshelfFragment1：多分组时 TitleBar 通过 contentLayout
    // 把可滚动 TabLayout 嵌入 Toolbar 内容区，与右侧菜单图标同一行，
    // 而不是作为 bottom 置于顶栏下方第二行（会导致顶栏过高且左右错位）
    Widget title = Text(AppStrings.bookshelf);
    if (state.hasGroupTabs) {
      final controller = _ensureTabController(state.groups.length);
      _syncTabControllerIndex(state.selectedGroupIndex);
      title = TabBar(
        controller: controller,
        isScrollable: true, // 原版 tabMode = MODE_SCROLLABLE
        tabAlignment: TabAlignment.start,
        // [审计修复 §3.1] AppBar 内 TabBar 必须显式白色系前景，
        // 否则继承全局 tabBarTheme 的 primary 色与 AppBar 背景同色不可见 — Qoder
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white70,
        indicatorColor: Colors.white,
        tabs: state.groups.map((g) => Tab(text: g.groupName)).toList(),
      );
    }
    return AppBar(
      title: title,
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: AppStrings.search,
          onPressed: () => Navigator.pushNamed(context, AppRoutes.search),
        ),
        // 原版 main_bookshelf.xml 无常驻视图切换按钮，网格/列表切换在溢出菜单「书架布局」
        PopupMenuButton<String>(
          onSelected: (value) => _handleMenuAction(context, ref, value),
          itemBuilder: (_) => [
            // 对齐安卓原版 main_bookshelf.xml 溢出菜单
            PopupMenuItem(value: 'update_all', child: Text(AppStrings.updateAll)),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'import', child: Text(AppStrings.addLocalBook)),
            const PopupMenuItem(value: 'remote', child: Text('添加远程书籍')),
            const PopupMenuItem(value: 'add_url', child: Text('添加网址')),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'manage', child: Text(AppStrings.manageBookshelf)),
            const PopupMenuItem(value: 'cache_export', child: Text('缓存导出')),
            PopupMenuItem(value: 'groups', child: Text('分组管理')),
            const PopupMenuItem(value: 'layout', child: Text('书架布局')),
            const PopupMenuDivider(),
            // 分组展示模式切换（Flutter 扩展）
            PopupMenuItem(value: 'group_none', child: _buildGroupModeItem(ref, GroupMode.none, '不分组')),
            PopupMenuItem(value: 'group_source', child: _buildGroupModeItem(ref, GroupMode.bySource, '按来源分组')),
            PopupMenuItem(value: 'group_group', child: _buildGroupModeItem(ref, GroupMode.byGroup, '按分组显示')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'export_list', child: Text('导出书单')),
            const PopupMenuItem(value: 'import_list', child: Text('导入书单')),
            const PopupMenuItem(value: 'log', child: Text('日志')),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'sources', child: Text(AppStrings.sourceManagement)),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookshelfNotifierProvider);

    if (state.isLoading && state.books.isEmpty) {
      return LoadingIndicator(message: AppStrings.loadingBookshelf);
    }

    if (state.error != null && state.books.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(bookshelfNotifierProvider.notifier).refresh(),
      );
    }

    if (state.isEmpty) {
      // 安卓原版：纯居中灰字空状态
      return EmptyState(
        icon: Icons.library_books,
        title: AppStrings.emptyBookshelf,
        simple: true,
      );
    }

    return CustomRefreshIndicator(
      onRefresh: () => ref.read(bookshelfNotifierProvider.notifier).refresh(),
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          if (state.showStats) _buildStatsSliver(context, state),
          if (state.showRecentReading) _buildRecentReadingSliver(context, ref, state),
          // 分组模式：渲染分组头 + 分组内容
          if (state.groupMode != GroupMode.none)
            ..._buildGroupedSlivers(context, ref, state)
          else if (state.isGridView)
            _buildGridSliver(context, ref, state.currentGroupBooks)
          else
            _buildReorderableSliver(context, ref, state),
        ],
      ),
    );
  }

  Widget _buildStatsSliver(BuildContext context, BookshelfState state) {
    // 对标原版 view_bookshelf_header.xml tv_shelf_stats：单行摘要「N 本书 · M 在读」
    final shelfBooks = state.currentGroupBooks;
    final totalBooks = shelfBooks.length;
    final readingBooks = shelfBooks.where((b) => b.durChapterIndex > 0).length;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          '$totalBooks 本书 · $readingBooks 在读',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildRecentReadingSliver(BuildContext context, WidgetRef ref, BookshelfState state) {
    // 对标原版 continue_reading 行：最近阅读的一本书，点击继续阅读，长按打开书籍信息
    final continueBook = state.currentGroupBooks
        .where((b) => b.durChapterIndex > 0)
        .fold<Book?>(
          null,
          (latest, b) => (latest == null || b.durChapterTime > latest.durChapterTime)
              ? b
              : latest,
        );
    if (continueBook == null) return const SliverToBoxAdapter();
    final colorScheme = Theme.of(context).colorScheme;
    final percent = continueBook.totalChapterNum > 0
        ? '${((continueBook.durChapterIndex + 1) * 100 ~/ continueBook.totalChapterNum)}%'
        : '';
    return SliverToBoxAdapter(
      child: InkWell(
        onTap: () => _openBook(context, ref, continueBook),
        onLongPress: () => _openBookInfo(context, continueBook),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                AppStrings.recentReading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  continueBook.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  continueBook.durChapterTitle ?? AppStrings.unknownChapter,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                percent,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridSliver(BuildContext context, WidgetRef ref, List<Book> books) {
    // 响应式网格：按可用宽度动态计算列数（手机 3 列对齐原版 / 平板 4 列）
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
              return _buildGridItem(context, ref, books[index]);
            },
          ),
        );
      },
    );
  }

  Widget _buildReorderableSliver(BuildContext context, WidgetRef ref, BookshelfState state) {
    final shelfBooks = state.currentGroupBooks;
    return SliverReorderableList(
      itemCount: shelfBooks.length,
      // onReorderItem 的 newIndex 已按移除项调整，还原为 onReorder 语义后交给 Notifier
      onReorderItem: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex++;
        ref
            .read(bookshelfNotifierProvider.notifier)
            .reorderBook(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final book = shelfBooks[index];
        return BookListItem(
          key: ValueKey(book.bookUrl),
          book: book,
          onTap: () => _openBook(context, ref, book),
          // 安卓原版：长按直接打开书籍信息页
          onLongPress: () => _openBookInfo(context, book),
        );
      },
    );
  }

  Widget _buildGridItem(BuildContext context, WidgetRef ref, Book book) {
    // 稳定 ValueKey（bookUrl）避免数据变化时整网格重建；RepaintBoundary 隔离重绘区域
    final item = BookGridItem(
      key: ValueKey(book.bookUrl),
      title: book.name,
      coverUrl: book.customCoverUrl ?? book.coverUrl,
      unreadNum: unreadChapterNum(book),
      progress: bookReadProgress(book),
      onTap: () => _openBook(context, ref, book),
      // 封面长按：打开书籍信息页（对齐安卓原版）
      onCoverLongPress: () => _openBookInfo(context, book),
      // 标题/信息区域长按：弹出操作菜单
      onInfoLongPress: () => _showBookActionSheet(context, ref, book),
    );
    return RepaintBoundary(child: item);
  }

  // ===== 操作 =====

  void _openBook(BuildContext context, WidgetRef ref, Book book) {
    // 对标原版 startActivityForBook：未读书籍进书籍信息页，已读进阅读器
    if (book.durChapterIndex <= 0 && book.durChapterPos <= 0) {
      _openBookInfo(context, book);
      return;
    }
    // 阅读器状态由 ReaderNotifier（Riverpod）管理
    ref.read(readerNotifierProvider.notifier).openBook(book);
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

  /// 打开书籍信息编辑页，保存成功后刷新书架
  Future<void> _editBookInfo(BuildContext context, WidgetRef ref, Book book) async {
    final saved = await Navigator.pushNamed<bool>(
      context,
      AppRoutes.editBookInfo,
      arguments: book,
    );
    if (saved == true) {
      ref.read(bookshelfNotifierProvider.notifier).refresh();
    }
  }

  /// 分享书籍（对齐 Android 原版：书名 + 作者 + 来源）
  void _shareBook(Book book) {
    Share.share(buildBookShareText(book));
  }

  /// 长按标题/信息区域弹出操作菜单（对齐安卓原版底部菜单）
  void _showBookActionSheet(BuildContext context, WidgetRef ref, Book book) {
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
                  _editBookInfo(context, ref, book);
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
                  _confirmDeleteBook(context, ref, book);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 确认删除书籍对话框
  void _confirmDeleteBook(BuildContext context, WidgetRef ref, Book book) {
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
                ref.read(bookshelfNotifierProvider.notifier).removeBook(book.bookUrl);
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
  Future<void> _addLocalBook(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(bookshelfNotifierProvider.notifier);
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
        await notifier.importLocalBook(path);
        successCount++;
      } catch (_) {
        failures.add(file.name);
      }
    }

    // 刷新书架，确保与后端数据一致
    await notifier.refresh();

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

  // ===== 分组展示 =====

  /// 分组模式菜单项（带勾选标记）
  Widget _buildGroupModeItem(WidgetRef ref, GroupMode mode, String label) {
    final current = ref.read(bookshelfNotifierProvider).groupMode;
    return Row(
      children: [
        Icon(
          current == mode ? Icons.radio_button_checked : Icons.radio_button_off,
          size: 20,
        ),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }

  /// 构建分组 slivers：每组一个头部 + 网格/列表
  List<Widget> _buildGroupedSlivers(BuildContext context, WidgetRef ref, BookshelfState state) {
    final groups = state.groupedBooks;
    final slivers = <Widget>[];
    for (final entry in groups.entries) {
      // 分组头
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  entry.key,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${entry.value.length}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      // 分组内容
      if (state.isGridView) {
        slivers.add(_buildGridSliver(context, ref, entry.value));
      } else {
        slivers.add(_buildListSliver(context, ref, entry.value));
      }
    }
    return slivers;
  }

  /// 列表模式（非拖拽，用于分组内展示）
  Widget _buildListSliver(BuildContext context, WidgetRef ref, List<Book> books) {
    return SliverList.builder(
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return BookListItem(
          key: ValueKey(book.bookUrl),
          book: book,
          onTap: () => _openBook(context, ref, book),
          onLongPress: () => _openBookInfo(context, book),
        );
      },
    );
  }

  void _handleMenuAction(BuildContext context, WidgetRef ref, String action) {
    switch (action) {
      case 'update_all':
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.checkingUpdate)),
        );
      case 'import':
        // 原版添加本地：直接选择本地书籍文件导入
        _addLocalBook(context, ref);
      case 'remote':
        Navigator.pushNamed(context, AppRoutes.remoteBooks);
      case 'add_url':
        _todo(context, '添加网址');
      case 'manage':
        // 进入书架管理页（对标原版 BookshelfManageActivity）
        Navigator.pushNamed(context, AppRoutes.bookshelfManage);
      case 'cache_export':
        _todo(context, '缓存导出');
      case 'groups':
        Navigator.pushNamed(context, AppRoutes.bookGroups);
      case 'layout':
        // 原版书架布局切换：Flutter 映射为网格/列表视图切换
        ref.read(bookshelfNotifierProvider.notifier).toggleViewMode();
      case 'group_none':
        ref.read(bookshelfNotifierProvider.notifier).setGroupMode(GroupMode.none);
      case 'group_source':
        ref.read(bookshelfNotifierProvider.notifier).setGroupMode(GroupMode.bySource);
      case 'group_group':
        ref.read(bookshelfNotifierProvider.notifier).setGroupMode(GroupMode.byGroup);
      case 'export_list':
        _exportBookshelf(context, ref);
      case 'import_list':
        Navigator.pushNamed(context, AppRoutes.importBooks);
      case 'log':
        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
      case 'sources':
        Navigator.pushNamed(context, AppRoutes.sources);
    }
  }

  /// 尚未移植的原版功能统一提示
  void _todo(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」功能尚未移植')),
    );
  }

  /// 导出书单（对标原版 export_bookshelf）：书名+作者文本分享
  void _exportBookshelf(BuildContext context, WidgetRef ref) {
    final books = ref.read(bookshelfNotifierProvider).books;
    if (books.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书架为空，无可导出的书单')),
      );
      return;
    }
    final lines = books
        .map((b) => b.author.isNotEmpty ? '${b.name} - ${b.author}' : b.name)
        .join('\n');
    Share.share('Legado 书单导出：\n$lines');
  }
}
