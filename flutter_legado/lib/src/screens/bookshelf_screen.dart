import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../bridge/ffi.dart' show BridgeError;
import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../utils/book_open_utils.dart';
import '../widgets/book_grid_item.dart';
import '../widgets/book_list_item.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/skeleton.dart'; // [LAYOUT_PLAN P4] 首屏 Skeleton 接线

/// 书架页面（Riverpod ConsumerStatefulWidget）
///
/// 状态由 [BookshelfNotifier] 管理，Widget 层仅负责渲染与交互。
/// Notifier 在 build() 时自动加载数据，无需 initState。
/// [骨架对齐 2.0.260 | 台账 1-3] 布局骨架（对齐参考 03/03b 截图）：
/// 可折叠大标题「书架」→ 常驻分组 tab 行（无分组数据时回落单一「全部」
/// tab）→ 2 列大封面网格（卡片=封面+居中书名）。搜索入口收敛为顶栏
/// 🔍 图标；页内全宽搜索条与统计/最近阅读行已按红线清理移除。
class BookshelfScreen extends ConsumerStatefulWidget {
  /// 回滚顶部信号（主页双击底栏书架项时自增，对标原版 gotoTop）
  final ValueNotifier<int>? scrollTopSignal;

  const BookshelfScreen({super.key, this.scrollTopSignal});

  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfScreenState();
}

// [骨架对齐 2.0.260 | 台账 1-3] 分组数变化时 _ensureTabController 会重建
// TabController（生命周期内多个 ticker），故用 TickerProviderStateMixin
// 而非 SingleTickerProviderStateMixin（后者对第二个 ticker 抛断言）
class _BookshelfScreenState extends ConsumerState<BookshelfScreen>
    with TickerProviderStateMixin {
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
    final state = ref.watch(bookshelfNotifierProvider);
    // [骨架对齐 2.0.260 | 台账 1-3] 主内容/空态：大标题 + 分组 tab 行以
    // sliver 形式并入下方 CustomScrollView（对齐参考 03/03b 截图：空态
    // 同样保留「书架」大标题 + 分组 tab 行）；加载/错误态保留标准
    // LegadoAppBar。
    final plainAppBar = (state.isLoading && state.books.isEmpty) ||
        (state.error != null && state.books.isEmpty);
    return Scaffold(
      appBar: plainAppBar ? _buildAppBar(context, ref) : null,
      body: _buildBody(context, ref),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookshelfNotifierProvider);
    return LegadoAppBar(
      // [骨架对齐 2.0.260 | 台账 1-3] 分组 tab 行常驻于 sliver 头部
      // （含空态）；标准栏（加载/错误态）仅显示「书架」大标题
      title: Text(AppStrings.bookshelf),
      // [UI-fix 2.0.258] 选择模式下加载态/错误态顶栏同样切换为批量动作集
      actions: state.isBatchMode
          ? _buildBatchAppBarActions(context, ref)
          : _buildAppBarActions(context, ref),
    );
  }

  /// [UI-fix 2.0.258] 选择模式顶栏动作集（全选/反选/删除/取消，对标原版
  /// selectMode 顶栏切换语义）：进入选择模式后顶栏由「搜索+溢出菜单」
  /// 切换为批量操作；tooltip 会暴露为 Android 无障碍 content-desc，
  /// 保证 uiautomator dump 可检索到 全选/反选/删除/取消 关键词。
  List<Widget> _buildBatchAppBarActions(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(bookshelfNotifierProvider.notifier);
    return [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: '全选',
        onPressed: notifier.selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.flip_rounded),
        tooltip: '反选',
        onPressed: notifier.invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete_rounded),
        tooltip: '删除',
        onPressed: () => _confirmDeleteSelected(context, ref),
      ),
      IconButton(
        icon: const Icon(Icons.close_rounded),
        tooltip: '取消',
        onPressed: notifier.toggleBatchMode,
      ),
    ];
  }

  /// [UI-fix 2.0.258] 选择模式删除确认（对齐原版批量删除前二次确认，
  /// 防误删；确认后逐本删除并退出选择模式）
  Future<void> _confirmDeleteSelected(
      BuildContext context, WidgetRef ref) async {
    final state = ref.read(bookshelfNotifierProvider);
    final count = state.selectedUrls.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定删除选中的 $count 本书籍吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(bookshelfNotifierProvider.notifier).deleteSelectedBooks();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已删除 $count 本书籍')));
  }

  /// 分组 TabBar（对标原版 BookshelfFragment1：可滚动 TabLayout）
  ///
  /// [骨架对齐 2.0.260 | 台账 1-3] tab 行常驻：数据未就绪（groups 为空，
  /// 如加载失败）时回落单一「全部」tab（对标参考空态截图 03）；
  /// 选中态与切换经 [BookshelfNotifier.selectGroup] 持久化并真正过滤列表
  /// （[BookshelfStateGrouping.currentGroupBooks]）。
  Widget _buildGroupTabBar(BuildContext context, BookshelfState state) {
    final groups = state.groups.isNotEmpty
        ? state.groups
        : const [BookGroup(groupId: BookGroupId.all, groupName: '全部')];
    final controller = _ensureTabController(groups.length);
    _syncTabControllerIndex(state.selectedGroupIndex.clamp(0, groups.length - 1));
    final colorScheme = Theme.of(context).colorScheme;
    // [LAYOUT_MOTION_AUDIT L3] Tab 文案走 labelLargeEmphasized（M3 labelLarge + Medium 强调）
    final labelStyle = Theme.of(context)
        .textTheme
        .labelLarge
        ?.copyWith(fontWeight: FontWeight.w500);
    return TabBar(
      controller: controller,
      isScrollable: true, // 原版 tabMode = MODE_SCROLLABLE
      tabAlignment: TabAlignment.start,
      // [LAYOUT_MOTION_AUDIT L3] edgePadding 0（Flutter 侧等价 padding 置零）
      padding: EdgeInsets.zero,
      // [LAYOUT_MOTION_AUDIT L3] minTabWidth 0（Flutter 侧等价 labelPadding 置零）
      labelPadding: EdgeInsets.zero,
      // [LAYOUT_MOTION_AUDIT L3] 无分割线
      dividerColor: Colors.transparent,
      // [LAYOUT_MOTION_AUDIT L3] 无分割线
      dividerHeight: 0,
      // [LAYOUT_MOTION_AUDIT L3] 选中走 primary
      labelColor: colorScheme.primary,
      // [LAYOUT_MOTION_AUDIT L3] 未选中走 onSurfaceVariant
      unselectedLabelColor: colorScheme.onSurfaceVariant,
      // [LAYOUT_MOTION_AUDIT L3] labelLargeEmphasized
      labelStyle: labelStyle,
      // [LAYOUT_MOTION_AUDIT L3] labelLargeEmphasized
      unselectedLabelStyle: labelStyle,
      // [MD3 Batch 2] 前景走全局 tabBarTheme（onSurface/onSurfaceVariant +
      // primary 指示器），与 M3 AppBar surface 背景配对，不再硬编码白色
      // [骨架对齐 2.0.260] 选中 tab = primary 字色 + 短下划线（对齐参考 03b）
      tabs: groups.map((g) => Tab(text: g.groupName)).toList(),
    );
  }

  List<Widget> _buildAppBarActions(BuildContext context, WidgetRef ref) {
    return [
      // [UI-fix v2.0.175] 恢复搜索图标（原版 main_bookshelf.xml actionbar
      // 自带搜索项，红线对齐；Dynamic 搜索行双入口并存——用户报障找不到搜索）
      IconButton(
        icon: const Icon(Symbols.search_rounded),
        tooltip: AppStrings.search,
        onPressed: () => Navigator.pushNamed(context, AppRoutes.search),
      ),
      // 原版 main_bookshelf.xml 无常驻视图切换按钮，网格/列表切换在溢出菜单「书架布局」
      PopupMenuButton<String>(
        onSelected: (value) => _handleMenuAction(context, ref, value),
        itemBuilder: (_) => [
          // [UI-parity 2.0.257] 首屏 11 项对齐参考版书架溢出菜单顺序
          // （添加远程书籍/添加本地/更新目录/书架布局/分组管理/添加网址/
          // 选择模式/书架管理/导出书单/导入书单/日志），使「导出书单/导入
          // 书单/日志」首屏可见（此前 14 项+4 分割线把三项挤到滚动区外，
          // 台账 1-4② 误判为功能缺失）
          const PopupMenuItem(value: 'remote', child: Text('添加远程书籍')),
          PopupMenuItem(value: 'import', child: Text(AppStrings.addLocalBook)),
          PopupMenuItem(value: 'update_all', child: Text(AppStrings.updateAll)),
          const PopupMenuItem(value: 'layout', child: Text('书架布局')),
          PopupMenuItem(value: 'groups', child: Text('分组管理')),
          const PopupMenuItem(value: 'add_url', child: Text('添加网址')),
          PopupMenuItem(value: 'select_mode', child: Text('选择模式')),
          PopupMenuItem(value: 'manage', child: Text(AppStrings.manageBookshelf)),
          const PopupMenuItem(value: 'export_list', child: Text('导出书单')),
          const PopupMenuItem(value: 'import_list', child: Text('导入书单')),
          const PopupMenuItem(value: 'log', child: Text('日志')),
          const PopupMenuDivider(),
          // 我方特有项（双基准原则保留不删）：离线缓存（对应原版
          // menu_download 缓存/导出）+ 分组展示模式 + 书源管理
          const PopupMenuItem(value: 'offline_cache', child: Text('离线缓存')),
          PopupMenuItem(value: 'group_none', child: _buildGroupModeItem(ref, GroupMode.none, '不分组')),
          PopupMenuItem(value: 'group_source', child: _buildGroupModeItem(ref, GroupMode.bySource, '按来源分组')),
          PopupMenuItem(value: 'group_group', child: _buildGroupModeItem(ref, GroupMode.byGroup, '按分组显示')),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'sources', child: Text(AppStrings.sourceManagement)),
        ],
      ),
    ];
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookshelfNotifierProvider);

    if (state.isLoading && state.books.isEmpty) {
      // [LAYOUT_PLAN P4] 首屏 Skeleton 接线：按当前视图模式渲染网格/列表骨架
      // （shimmer 1200ms 已在 skeleton.dart 实现），替代整页 LoadingIndicator
      if (state.isGridView) {
        // [骨架对齐 2.0.260] 骨架与正式 2 列大封面网格同构
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 5 / 7,
          ),
          itemCount: 6,
          itemBuilder: (_, _) => const GridSkeletonItem(),
        );
      }
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: 8,
        itemBuilder: (_, _) => const ListSkeletonItem(),
      );
    }

    if (state.error != null && state.books.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(bookshelfNotifierProvider.notifier).refresh(),
      );
    }

    if (state.isEmpty) {
      // [骨架对齐 2.0.260 | 台账 1-3] 空态对齐参考 03 截图：大标题「书架」
      // + 分组 tab 行常驻，正文区居中颜文字彩蛋（kaomoji 模式为 2026-08-29
      // 用户授权彩蛋，点击换颜文字）
      return CustomScrollView(
        slivers: [
          _buildHeaderSliver(context, ref, state),
          SliverFillRemaining(
            hasScrollBody: false,
            child: state.isBatchMode
                // [UI-fix 2.0.258] 选择模式 + 空书架（对齐参考版 05 截图：
                // 空态上方仍呈现「已选0本 · 共0本」胶囊）
                ? Column(
                    children: [
                      _buildBatchSummaryCard(context, ref, state),
                      Expanded(
                        child: EmptyState(
                          icon: Symbols.library_books_rounded,
                          title: AppStrings.emptyBookshelf,
                          kaomoji: true,
                        ),
                      ),
                    ],
                  )
                // [骨架对齐 2.0.260 | 台账 1-3] 溢出防护：剩余区高度不足
                // （展开 LargeTitle≈152 + tab 行 56 后，矮视口仅剩 ~90px）时
                // 颜文字列（自然高 ~106px）会 RenderFlex overflow。经
                // FittedBox(scaleDown) 包裹 UnconstrainedBox(仅宽度受限)：
                // 内容按自然高度布局后整体等比缩放居中，正常视口比例 1.0
                // （像素不变），矮视口优雅降级不溢出
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: UnconstrainedBox(
                      constrainedAxis: Axis.horizontal,
                      child: EmptyState(
                        icon: Symbols.library_books_rounded,
                        title: AppStrings.emptyBookshelf,
                        kaomoji: true,
                      ),
                    ),
                  ),
          ),
        ],
      );
    }

    return CustomRefreshIndicator(
      onRefresh: () => ref.read(bookshelfNotifierProvider.notifier).refresh(),
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // [骨架对齐 2.0.260 | 台账 1-3] 头部 = 可折叠大标题「书架」 +
          // 常驻分组 tab 行（bottom，对齐参考 03b 截图）；搜索入口收敛为
          // 顶栏 🔍 图标（_buildAppBarActions），页内全宽搜索条移除
          _buildHeaderSliver(context, ref, state),
          // [UI-fix 2.0.258] 批量模式摘要卡位于头部之后（对齐参考版：
          // 标题/Tab →「已选N本 · 共M本」胶囊 → 书列表）
          if (state.isBatchMode)
            SliverToBoxAdapter(
              child: _buildBatchSummaryCard(context, ref, state),
            ),
          // 分组模式：渲染分组头 + 分组内容
          if (state.groupMode != GroupMode.none)
            ..._buildGroupedSlivers(context, ref, state)
          else if (state.isGridView)
            _buildGridSliver(context, ref, state.currentGroupBooks)
          else
            _buildReorderableSliver(context, ref, state),
          // [UI_SYNC_REFACTOR T3] 底部批量工具条（batch 模式且选中时显示）
          if (state.isBatchMode && state.selectedUrls.isNotEmpty)
            SliverToBoxAdapter(
              child: _buildBatchBottomBar(context, ref, state),
            ),
        ],
      ),
    );
  }

  /// [骨架对齐 2.0.260 | 台账 1-3] 头部 sliver：可折叠 LargeTitle「书架」
  /// + 常驻分组 tab 行（bottom）。空态/内容态共用，保证 tab 行与选中态
  /// 始终可见（对齐参考 03/03b 截图骨架）。
  Widget _buildHeaderSliver(
      BuildContext context, WidgetRef ref, BookshelfState state) {
    return LegadoTabRootHeaderSliver(
      large: true,
      // [骨架对齐 2.0.260 | 台账 1-3] 大标题 28sp：参考 03b 截图量测字高
      // 79px（480dpi 下 ≈28sp，与首页 2.0.259 大标题先例一致）
      largeTitleFontSize: 28,
      // [骨架对齐 2.0.260 | 台账 1-3] 展开态 164dp：SliverAppBar.large 的
      // 显式 expandedHeight 被 SDK 原样使用（large 变体 delegate maxExtent =
      // topPadding + expandedHeight，显式值不额外加 bottom 高——仅默认分支
      // 112 + bottomHeight 计入），即「状态栏之外的头部总高」且须含 TabBar
      // 56dp：164 = 顶行 64 + 标题区 44 + TabBar 56——对齐参考 03b 量测：
      // 状态栏 24 + 顶行 64 + 标题区 44（28sp 标题字身 99–121dp 居中于
      // 88–132dp 带）+ TabBar 56（下划线底 551px@3x）= 头部总 188dp
      // （Scaffold 无 AppBar 的 body 内 topPadding = 24dp）。传 108 会被
      // delegate 钳制至 minExtent 144dp 致标题带归零、大标题不渲染（实机
      // 复验发现）
      expandedHeight: 164,
      title: Text(AppStrings.bookshelf),
      // [UI-fix 2.0.258] 选择模式顶栏切换为批量动作集（全选/反选/删除/取消）
      actions: state.isBatchMode
          ? _buildBatchAppBarActions(context, ref)
          : _buildAppBarActions(context, ref),
      // 分组 tab 行（TabBar 默认高 kToolbarHeight，Tab 高度 40dp）
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: _buildGroupTabBar(context, state),
      ),
    );
  }

  Widget _buildGridSliver(BuildContext context, WidgetRef ref, List<Book> books) {
    // [骨架对齐 2.0.260 | 台账 1-3] 2 列大封面网格（对齐参考 03b 截图：
    // 卡片=大封面+居中标题，无未读徽标/进度条；原响应式 3/4/6 列与
    // 84 封面限宽移除，红线清理）
    return SliverPadding(
      // 内容边距：左右 12 + 上下 8（对齐参考目测间距）
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          // 网格间距 12dp（大封面骨架）
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          // [LAYOUT_MOTION_AUDIT L3] 单元格 aspect 5:7（HapeLee 封面比例）
          childAspectRatio: 5 / 7,
        ),
        itemCount: books.length,
        itemBuilder: (context, index) => _buildGridItem(context, ref, books[index]),
      ),
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
        // [UI_SYNC_REFACTOR T3] 批量模式点击 = 切换选中
        final batch = ref.watch(bookshelfNotifierProvider
            .select((s) => s.isBatchMode));
        if (batch) {
          // [UI-fix 2.0.258] 列表勾选态：选中高亮 + 尾部对勾，点按切换
          final selected = ref.watch(bookshelfNotifierProvider
              .select((s) => s.selectedUrls.contains(book.bookUrl)));
          return _buildBatchListItem(context, ref, book, selected);
        }
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
    // [UI_SYNC_REFACTOR T3] 批量模式点击 = 切换选中
    final batch = ref.watch(bookshelfNotifierProvider
        .select((s) => s.isBatchMode));
    if (batch) {
      return _buildBatchGridItem(context, ref, book);
    }
    // 稳定 ValueKey（bookUrl）避免数据变化时整网格重建；RepaintBoundary 隔离重绘区域
    // [骨架对齐 2.0.260 | 台账 1-3] 卡片=封面+居中书名（对齐参考 03b）：
    // 未读徽标/阅读进度不再呈现（参考卡片无此两要素）；未读/阅读进度能力
    // 仍可从封面长按 → 书籍信息页「在读」行可达（book_info 页保留）
    final item = BookGridItem(
      key: ValueKey(book.bookUrl),
      title: book.name,
      coverUrl: book.customCoverUrl ?? book.coverUrl,
      sourceOrigin: book.origin,
      // Hero 封面过渡（书架↔详情，key=book url）
      // [LAYOUT_MOTION_AUDIT M1] tag 统一 book-cover:（HapeLee 同义键）
      heroTag: 'book-cover:${book.bookUrl}',
      onTap: () => _openBook(context, ref, book),
      // 封面长按：打开书籍信息页（对齐安卓原版；未读/进度可达入口）
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
    // 失败原因显式化（体检 §三.13）：rust 侧对不支持的 MOBI 变体返回明确文案
    // （如「不支持 LZMA 压缩格式」「该 MOBI 文件已加密」），须透传给用户；
    // 详情最多展示 3 条，避免 SnackBar 溢出
    final failureDetails = <String>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null) {
        failures.add(file.name);
        continue;
      }
      try {
        await notifier.importLocalBook(path);
        successCount++;
      } catch (e) {
        failures.add(file.name);
        if (failureDetails.length < 3) {
          final msg = e is BridgeError ? e.message : '$e';
          failureDetails.add('${file.name}：$msg');
        }
      }
    }

    // 刷新书架，确保与后端数据一致
    await notifier.refresh();

    final messages = <String>[];
    if (successCount > 0) messages.add('已导入 $successCount 本书籍');
    if (failures.isNotEmpty) {
      final detail = failureDetails.join('；');
      final more = failures.length > failureDetails.length
          ? ' 等 ${failures.length} 本'
          : '';
      messages.add('导入失败：$detail$more');
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
          current == mode ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded,
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
        // [UI-fix 2.0.258] 选择模式下分组列表同样走勾选态（与主列表一致）
        final batch = ref.watch(bookshelfNotifierProvider
            .select((s) => s.isBatchMode));
        if (batch) {
          final selected = ref.watch(bookshelfNotifierProvider
              .select((s) => s.selectedUrls.contains(book.bookUrl)));
          return _buildBatchListItem(context, ref, book, selected);
        }
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
      case 'select_mode':
        ref.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
        break;
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

  /// [UI_SYNC_REFACTOR T3] 批量模式网格瓦片（选中高亮 + 勾选角标）
  Widget _buildBatchGridItem(BuildContext context, WidgetRef ref, Book book) {
    final selected = ref.watch(bookshelfNotifierProvider
        .select((s) => s.selectedUrls.contains(book.bookUrl)));
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => ref
          .read(bookshelfNotifierProvider.notifier)
          .toggleSelect(book.bookUrl),
      child: Container(
        decoration: selected
            ? BoxDecoration(
                color: cs.secondaryContainer.withValues(alpha: 0.3),
                // [骨架对齐 2.0.260] 与 2 列大封面卡片同圆角 12
                borderRadius: BorderRadius.circular(12),
              )
            : null,
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BookGridItem(
                  key: ValueKey(book.bookUrl),
                  title: book.name,
                  coverUrl: book.customCoverUrl ?? book.coverUrl,
                  unreadNum: 0,
                  sourceOrigin: book.origin,
                ),
              ),
            ),
            if (selected)
              Positioned(
                right: 4,
                top: 4,
                child: Icon(
                  Symbols.check_circle_rounded,
                  size: 22,
                  color: cs.primary,
                  fill: 1,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// [UI-fix 2.0.258] 选择模式列表行（勾选态）：选中高亮 + 尾部对勾，
  /// 点按切换选中；文案对齐参考版「已选N本 · 共M本」胶囊口径
  ///
  /// [UI-fix 2.0.258 修正] 根因：`SliverReorderableList` 的惰性 `itemBuilder`
  /// 要求返回的每个 item 必须携带 `Key`（reorderable_list.dart 断言
  /// `child.key != null`，否则该 item 构建期抛异常、整行不渲染）。正常态
  /// 分支返回 `BookListItem(key: ValueKey(bookUrl))` 天然满足；而批量态此前
  /// 返回无 key 的 `Material`，导致选择模式下书卡列表整块空白（台账 1-5 P0
  /// 复审缺陷）。现给外层 `Material` 补上稳定 `ValueKey(bookUrl)` 修复。
  Widget _buildBatchListItem(
      BuildContext context, WidgetRef ref, Book book, bool selected) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: ValueKey(book.bookUrl),
      color: selected
          ? cs.secondaryContainer.withValues(alpha: 0.3)
          : cs.surface,
      child: Row(
        children: [
          Expanded(
            child: BookListItem(
              key: ValueKey(book.bookUrl),
              book: book,
              onTap: () => ref
                  .read(bookshelfNotifierProvider.notifier)
                  .toggleSelect(book.bookUrl),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 22,
              color: selected ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 选择模式「已选N本 · 共M本」胶囊（对齐参考版 05 截图：× 退出钮 + 计数）
  ///
  /// [UI-fix 2.0.258] 根因修复：此前本卡构建为 `Positioned` 子树却挂在
  /// SliverToBoxAdapter（非 Stack 父级）下，布局期抛异常（debug 报
  /// "A Positioned widget must be wrapped with its parent"，release
  /// 帧渲染中断），导致选择模式整屏灰白空白（台账 1-5 P0）。
  /// 现改为常规 Center 布局，不再依赖 Stack 定位。
  Widget _buildBatchSummaryCard(
      BuildContext context, WidgetRef ref, BookshelfState state) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        child: Material(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: '退出选择',
                  onPressed: () => ref
                      .read(bookshelfNotifierProvider.notifier)
                      .toggleBatchMode(),
                ),
                Text(
                  '已选 ${state.selectedUrls.length} 本',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  ' · 共 ${state.currentGroupBooks.length} 本',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// [UI_SYNC_REFACTOR T3] 底部批量工具条（对齐参考 SelectionBottomBar）
  Widget _buildBatchBottomBar(
      BuildContext context, WidgetRef ref, BookshelfState state) {
    final cs = Theme.of(context).colorScheme;
    final count = state.selectedUrls.length;
    if (count == 0) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(32),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: '全选',
              onPressed: () =>
                  ref.read(bookshelfNotifierProvider.notifier).selectAll(),
            ),
            IconButton(
              icon: const Icon(Icons.flip_rounded),
              tooltip: '反选',
              onPressed: () => ref
                  .read(bookshelfNotifierProvider.notifier)
                  .invertSelection(),
            ),
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: '批量下载',
              onPressed: count > 0
                  ? () => _showSnack('批量下载 $count 本（对标原版批量下载）')
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_move_rounded),
              tooltip: '移动分组',
              onPressed: count > 0
                  ? () => _showSnack('移动分组 $count 本（对标原版 GroupSelectSheet）')
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}
