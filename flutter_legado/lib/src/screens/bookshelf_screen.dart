import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../utils/book_open_utils.dart';
import '../utils/book_progress_utils.dart';
import '../utils/responsive.dart';
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
        // [MD3 Batch 2] 前景走全局 tabBarTheme（onSurface/onSurfaceVariant +
        // primary 指示器），与 M3 AppBar surface 背景配对，不再硬编码白色
        tabs: state.groups.map((g) => Tab(text: g.groupName)).toList(),
      );
    }
    return LegadoAppBar(
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
            const PopupMenuItem(value: 'offline_cache', child: Text('离线缓存')),
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
      onReorderItem: (oldIndex, newIndex) async {
        if (newIndex > oldIndex) newIndex++;
        await ref
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
      sourceOrigin: book.origin,
      // Hero 封面过渡（书架↔详情，key=book url）
      heroTag: 'cover:${book.bookUrl}',
      unreadNum: unreadChapterNum(book),
      progress: bookReadProgress(book),
      onTap: () => _openBook(context, ref, book),
      // 封面长按：打开书籍信息页（对齐安卓原版）
      onCoverLongPress: () => _openBookInfo(context, book),
      // 书名区长按：与封面一致直达书籍信息（对齐原版 U1）
      onInfoLongPress: () => _openBookInfo(context, book),
    );
    return RepaintBoundary(child: item);
  }

  // ===== 操作 =====

  /// 对标原版 startActivityForBook：未读进书详；已读按 BookType 分流到
  /// video / audio / reader-comic / reader（勿固定文本阅读器）。
  /// — Reasonix + UI
  Future<void> _openBook(
      BuildContext context, WidgetRef ref, Book book) async {
    if (book.durChapterIndex <= 0 && book.durChapterPos <= 0) {
      _openBookInfo(context, book);
      return;
    }
    var typeBits = BookOpenUtils.typeBitsOf(book);
    // 书源媒体类型 / 视频启发式优先于抽图提升 — Reasonix + UI
    if (BookOpenUtils.isOnlineBook(book)) {
      try {
        final api = ref.read(bookApiProvider);
        final sources = await api.getBookSources();
        // 去掉尾斜杠，避免 `https://ukuzy.com/` 与 origin 失配 — Reasonix + UI
        String norm(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');
        final o = norm(book.origin);
        for (final s in sources) {
          if (norm(s.bookSourceUrl) == o || s.bookSourceUrl == book.origin) {
            typeBits = BookOpenUtils.resolveTypeBits(typeBits, s);
            break;
          }
        }
      } catch (_) {}
    }
    if (!context.mounted) return;
    final bookToOpen =
        typeBits != 0 ? book.copyWith(bookType: typeBits) : book;
    final route = BookOpenUtils.routeForTypeBits(typeBits);
    if (BookOpenUtils.needsReaderNotifier(route)) {
      ref.read(readerNotifierProvider.notifier).openBook(bookToOpen);
      await Navigator.pushNamed(context, route);
      return;
    }
    await Navigator.pushNamed(
      context,
      route,
      arguments: BookOpenUtils.argumentsForRoute(route, bookToOpen),
    );
  }

  /// 长按封面/书名直接打开书籍信息页（对齐安卓原版行为）
  void _openBookInfo(BuildContext context, Book book) {
    Navigator.pushNamed(
      context,
      AppRoutes.bookInfo,
      arguments: book,
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
        // [UI-fix v2.0.2 | 2026-08-06] 更新目录接通真实 refreshToc FFI（对标原版 updateBook 逐本刷新） — Qoder
        _updateAllBooks();
      case 'import':
        // 原版添加本地：直接选择本地书籍文件导入
        _addLocalBook(context, ref);
      case 'remote':
        Navigator.pushNamed(context, AppRoutes.remoteBooks);
      case 'add_url':
        // [UI-fix v2.0.2 | 2026-08-06] 添加网址接通 WebBook 入库链路（对标原版 addBookByUrl） — Qoder
        _showAddByUrlDialog();
      case 'manage':
        // 进入书架管理页（对标原版 BookshelfManageActivity）
        Navigator.pushNamed(context, AppRoutes.bookshelfManage);
      case 'offline_cache':
        // [UI-fix v2.0.17 | 2026-08-11] 离线缓存页（对齐原版书架菜单
        // menu_download → CacheActivity：书籍列表/缓存进度/下载控制/单本导出）
        // — Reasonix
        Navigator.pushNamed(context, AppRoutes.offlineCache);
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
        // [UI-fix v2.0.2 | 2026-08-06] 导出书单对齐 Kotlin exportBookshelf（JSON 数组文件） — Qoder
        _exportBookshelf();
      case 'import_list':
        // [UI-fix v2.0.2 | 2026-08-06] 导入书单对齐 Kotlin importBookshelf（url/json/文件） — Qoder
        _showImportBookshelfDialog();
      case 'log':
        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
      case 'sources':
        Navigator.pushNamed(context, AppRoutes.sources);
    }
  }

  /// 导出书单（对标 Kotlin BookshelfViewModel.exportBookshelf）：
  /// [UI-fix v2.0.2 | 2026-08-06] JSON 数组 [{name,author,intro}] 2 空格缩进，
  /// 输出 bookshelf.json 供分享（原版行为对齐） — Qoder
  Future<void> _exportBookshelf() async {
    final books = ref.read(bookshelfNotifierProvider).books;
    if (books.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书架为空，无可导出的书单')),
      );
      return;
    }
    final data = books
        .map((b) => {
              'name': b.name,
              'author': b.author,
              'intro': b.customIntro ?? b.intro ?? '',
            })
        .toList();
    final json = const JsonEncoder.withIndent('  ').convert(data);
    await Share.shareXFiles([
      XFile.fromData(
        utf8.encode(json),
        name: 'bookshelf.json',
        mimeType: 'application/json',
      ),
    ]);
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 更新目录 / 添加网址 / 导入书单 — Qoder =====

  /// 更新全部书籍目录（对标 Kotlin updateAllBooks：仅刷新允许更新的非本地书）
  Future<void> _updateAllBooks() async {
    final api = ref.read(bookApiProvider);
    final books = ref.read(bookshelfNotifierProvider).books;
    final targets = books
        .where((b) =>
            b.canUpdate &&
            b.origin != BookType.localTag &&
            !b.origin.startsWith(BookType.webDavTag))
        .toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有需要更新的书籍')),
      );
      return;
    }
    final progress = ValueNotifier<String>('准备中...');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (context, text, _) => AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
    var ok = 0;
    for (var i = 0; i < targets.length; i++) {
      final book = targets[i];
      progress.value = '正在更新 ${i + 1}/${targets.length}：${book.name}';
      try {
        await api.refreshToc(book.bookUrl, book.origin);
        ok++;
      } catch (e) {
        debugPrint('更新目录失败《${book.name}》: $e');
      }
    }
    if (!mounted) {
      progress.dispose();
      return;
    }
    Navigator.pop(context); // 关闭进度对话框
    progress.dispose();
    ref.read(bookshelfNotifierProvider.notifier).refresh();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('目录更新完成：成功 $ok/${targets.length} 本')),
    );
  }

  /// 添加网址对话框（对标 Kotlin showAddBookByUrlAlert，扩展书名字段作裸书兑底）
  Future<void> _showAddByUrlDialog() async {
    final urlCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加网址'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '输入书籍详情页 URL（多行可加多本）',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  hintText: '书名（可选，无法获取详情时兑底）',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final urls = urlCtrl.text
        .split(RegExp(r'[\n,;]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final fallbackName = nameCtrl.text.trim();
    urlCtrl.dispose();
    nameCtrl.dispose();
    if (confirmed != true || urls.isEmpty || !mounted) return;
    await _addBooksByUrl(urls, fallbackName);
  }

  /// 按 URL 逐本添加（对标 Kotlin BookshelfViewModel.addBookByUrl：
  /// bookUrlPattern 正则/域名匹配书源 → webbookInfo 取详情入库）
  Future<void> _addBooksByUrl(List<String> urls, String fallbackName) async {
    final api = ref.read(bookApiProvider);
    final messenger = ScaffoldMessenger.of(context);
    final existingUrls =
        ref.read(bookshelfNotifierProvider).books.map((b) => b.bookUrl).toSet();
    List<BookSource> sources;
    try {
      sources = await api.getEnabledBookSources();
    } catch (_) {
      sources = const [];
    }
    var ok = 0;
    var skip = 0;
    var fail = 0;
    for (final url in urls) {
      if (existingUrls.contains(url)) {
        skip++;
        continue;
      }
      try {
        final source = _matchSource(sources, url);
        Book? book;
        if (source != null) {
          final json = await api.webbookInfo(
            jsonEncode(source.toJson()),
            url,
          );
          book = Book.fromJson(jsonDecode(json) as Map<String, dynamic>);
        }
        // 无匹配书源时按输入书名创建裸 WebBook 入库（任务要求；
        // Kotlin 原版此处报「没有匹配的书源」，Flutter 侧放宽为兑底入库）
        book ??= Book(
          bookUrl: url,
          name: fallbackName.isNotEmpty ? fallbackName : url,
          originName: '网页书籍',
        );
        await api.addBook(book);
        existingUrls.add(url);
        ok++;
      } catch (e) {
        fail++;
        debugPrint('添加网址失败 $url: $e');
      }
    }
    if (!mounted) return;
    ref.read(bookshelfNotifierProvider.notifier).refresh();
    messenger.showSnackBar(
      SnackBar(content: Text('添加网址完成：成功 $ok，跳过 $skip，失败 $fail')),
    );
  }

  /// URL 匹配书源（对标 Kotlin addBookByUrl：先 bookUrlPattern 正则，
  /// 后按主域名兑底）
  BookSource? _matchSource(List<BookSource> sources, String url) {
    for (final s in sources) {
      final pattern = s.bookUrlPattern;
      if (pattern == null || pattern.isEmpty) continue;
      try {
        if (RegExp(pattern).hasMatch(url)) return s;
      } catch (_) {
        // 非法正则忽略（部分书源 pattern 非标准正则）
      }
    }
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) {
      for (final s in sources) {
        final sUri = Uri.tryParse(s.bookSourceUrl);
        if (sUri != null && sUri.host == uri.host) return s;
      }
    }
    return null;
  }

  /// 导入书单对话框（对标 Kotlin importBookshelfAlert：
  /// url/json 输入框 + 选择 txt/json 文件）
  Future<void> _showImportBookshelfDialog() async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入书单'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: '输入书单 URL 或 JSON 数组',
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  final picked = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: const ['txt', 'json'],
                  );
                  final path =
                      picked == null || picked.files.isEmpty
                          ? null
                          : picked.files.first.path;
                  if (path != null) {
                    try {
                      ctrl.text = await File(path).readAsString();
                    } catch (e) {
                      debugPrint('读取书单文件失败: $e');
                    }
                  }
                },
                child: const Text('选择文件（txt/json）'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final input = ctrl.text.trim();
    ctrl.dispose();
    if (confirmed != true || input.isEmpty || !mounted) return;
    await _importBookshelf(input);
  }

  /// 导入书单（对标 Kotlin importBookshelf：url → httpGet 拉取，
  /// JSON 数组 → 逐本搜索入库；已在架跳过）
  Future<void> _importBookshelf(String input) async {
    final api = ref.read(bookApiProvider);
    final messenger = ScaffoldMessenger.of(context);
    var content = input;
    if (content.startsWith('http://') || content.startsWith('https://')) {
      try {
        content = (await api.httpGet(content)).trim();
      } catch (e) {
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('拉取书单失败: $e')),
          );
        }
        return;
      }
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      decoded = null;
    }
    if (decoded is! List) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('书单格式不对（应为 URL 或 JSON 数组）')),
        );
      }
      return;
    }
    final shelf = ref.read(bookshelfNotifierProvider).books;
    final existing = shelf.map((b) => '${b.name}|${b.author}').toSet();
    List<String> enabledUrls;
    try {
      enabledUrls = (await api.getEnabledBookSources())
          .map((s) => s.bookSourceUrl)
          .toList();
    } catch (_) {
      enabledUrls = const [];
    }
    var ok = 0;
    var skip = 0;
    var fail = 0;
    for (final item in decoded) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString().trim();
      final author = (item['author'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      if (existing.contains('$name|$author')) {
        skip++;
        continue;
      }
      try {
        // 对标 Kotlin WebBook.preciseSearchAwait（FFI preciseSearch）
        final hit = await api.preciseSearch(
          name,
          author,
          sourceUrls: enabledUrls.isEmpty ? null : enabledUrls,
        );
        final best = SearchResult.fromSearchBook(hit).book;
        await api.addBook(best);
        existing.add('$name|$author');
        ok++;
      } catch (e) {
        fail++;
        debugPrint('导入书单条目失败《$name》: $e');
      }
    }
    if (!mounted) return;
    ref.read(bookshelfNotifierProvider.notifier).refresh();
    messenger.showSnackBar(
      SnackBar(content: Text('书单导入完成：成功 $ok，跳过 $skip，失败 $fail')),
    );
  }
}
