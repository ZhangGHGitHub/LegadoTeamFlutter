import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../bridge/ffi.dart' show BridgeError;
import '../l10n/app_strings.dart';
import '../models/bookshelf_settings.dart';
import '../models/main_tab.dart';
import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/bookshelf_settings/bookshelf_settings_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart'
    show TopBarButtonStyle, uiSettingsListenable;
import '../routes.dart';
import '../services/book_api.dart' show DeleteBooksResult;
import '../services/cover_aspect_ratio.dart';
import '../services/local_book_store.dart';
import '../utils/book_open_utils.dart';
import '../utils/book_progress_utils.dart';
import '../utils/bookshelf_sort.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/app_progress_indicator.dart';
import '../widgets/book_display_tags_row.dart';
import '../widgets/book_grid_item.dart';
import '../widgets/book_list_item.dart';
import '../widgets/bookshelf/bookshelf_config_sheet.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/export_file_sheet.dart';
import '../widgets/md3_fast_scroller.dart';
import '../widgets/navigation/main_detail_pane_scope.dart';
import '../widgets/skeleton.dart'; // [LAYOUT_PLAN P4] 首屏 Skeleton 接线

/// 书架页面（Riverpod ConsumerStatefulWidget）
///
/// 状态由 [BookshelfNotifier] 管理，Widget 层仅负责渲染与交互。
/// Notifier 在 build() 时自动加载数据，无需 initState。
/// [骨架对齐 2.0.260 | 台账 1-3] 布局骨架（对齐参考 03/03b 截图）：
/// 可折叠大标题「书架」→ 常驻分组 tab 行（无分组数据时回落单一「全部」
/// tab）→ 3 列大封面网格（卡片=封面+居中书名，[parity fix 2.0.264] 列数
/// 2→3 修正）。搜索入口收敛为顶栏
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

  /// [设置批6a-1] 更新全部时的待更新数量（`showWaitUpCount` 顶栏角标）
  final ValueNotifier<int> _waitUpCount = ValueNotifier<int>(0);

  /// 书架内容实际宽度（多栏/窄 pane 小于窗口宽；配置面板列数提示用）
  double? _lastViewportWidth;

  @override
  void initState() {
    super.initState();
    widget.scrollTopSignal?.addListener(_onScrollTopSignal);
    // [批39] 封面比例设置/新解析比例 → 网格行高重算
    uiSettingsListenable.addListener(_onCoverLayoutChanged);
    coverAspectRatioRevision.addListener(_onCoverLayoutChanged);
  }

  @override
  void dispose() {
    uiSettingsListenable.removeListener(_onCoverLayoutChanged);
    coverAspectRatioRevision.removeListener(_onCoverLayoutChanged);
    widget.scrollTopSignal?.removeListener(_onScrollTopSignal);
    _scrollController.dispose();
    _waitUpCount.dispose();
    _tabController?.removeListener(_onTabControllerChanged);
    _tabController?.dispose();
    super.dispose();
  }

  /// 封面比例设置变化 / 新比例解析 → 重算网格行高
  void _onCoverLayoutChanged() {
    if (mounted) setState(() {});
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
  ///
  /// [设置批6a-1] Tab 列表可能因「隐藏空分组」而短于 `state.groups`，
  /// 此处把可见索引映射回数据源索引再持久化。
  void _onTabControllerChanged() {
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    final state = ref.read(bookshelfNotifierProvider);
    final settings = ref.read(bookshelfSettingsProvider);
    final visible = state.visibleGroups(hideEmpty: settings.hideEmptyGroups);
    if (controller.index < 0 || controller.index >= visible.length) return;
    final group = visible[controller.index];
    final allIndex =
        state.groups.indexWhere((g) => g.groupId == group.groupId);
    if (allIndex >= 0 && allIndex != state.selectedGroupIndex) {
      ref.read(bookshelfNotifierProvider.notifier).selectGroup(allIndex);
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
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: plainAppBar ? _buildAppBar(context, ref) : null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 记录书架栏实际宽度（配置面板列数提示与入口夹取同口径）
          _lastViewportWidth = constraints.maxWidth;
          return _buildBody(context, ref);
        },
      ),
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
      // [parity C3 B5] 与头部 sliver 同锁：书架顶栏裸图标（参考 03/03b）
      actionsStyle: TopBarButtonStyle.plain,
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
  /// 防误删；确认后批量删除并退出选择模式）
  ///
  /// [批35] 对齐参考版 `DeleteBooksConfirmDialog`：选中集合含本地/WebDAV
  /// 书时才显示「删除源文件」勾选（每次打开重置为不勾选）；勾选后由 Rust
  /// 删除 `bookUrl` 指向的磁盘文件，文件删除失败的逐条提示随结果返回。
  Future<void> _confirmDeleteSelected(
      BuildContext context, WidgetRef ref) async {
    final state = ref.read(bookshelfNotifierProvider);
    final count = state.selectedUrls.length;
    if (count == 0) return;
    // 仅当选中集合里存在本地书才提供「删除源文件」（对齐参考版 hasLocalBook）
    // [批35b P3-3] 用与 Rust `is_local_storage_book` 完全同构的判定：弹窗
    // 出现「删除源文件」的条件必须与 Rust 真正会尝试删文件的条件一致
    //（Rust 为真源，见 BookType.isLocalStorageBook）。
    final hasLocalBook = state.books.any(
      (b) =>
          state.selectedUrls.contains(b.bookUrl) &&
          BookType.isLocalStorageBook(b),
    );
    var deleteOriginal = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('删除书籍'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已选$count本'),
              if (hasLocalBook)
                InkWell(
                  onTap: () =>
                      setDialogState(() => deleteOriginal = !deleteOriginal),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Checkbox(
                          value: deleteOriginal,
                          onChanged: (v) =>
                              setDialogState(() => deleteOriginal = v ?? false),
                        ),
                        const Text('删除源文件'),
                      ],
                    ),
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
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    DeleteBooksResult result;
    try {
      result = await ref
          .read(bookshelfNotifierProvider.notifier)
          .deleteSelectedBooks(deleteOriginal: deleteOriginal);
    } catch (e) {
      if (!context.mounted) return;
      // BridgeError 未覆写 toString，必须取 message（否则提示 Instance of ...）
      final reason = e is BridgeError ? e.message : '$e';
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('删除失败：$reason')));
      return;
    }
    if (!context.mounted) return;
    // [批35b P3-5] 用 Rust 返回的实际删除数（选中后已被并发删除的不计入）；
    // 文件删除失败不阻断记录删除：先报删除数，再逐条列出失败原因。
    final deletedText = result.missing > 0
        ? '已删除 ${result.deleted} 本书籍（${result.missing} 本已不在书架）'
        : '已删除 ${result.deleted} 本书籍';
    final message = result.warnings.isEmpty
        ? deletedText
        : '$deletedText；部分源文件未删除：${result.warnings.join('；')}';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 分组 TabBar（对标原版 BookshelfFragment1：可滚动 TabLayout）
  ///
  /// [骨架对齐 2.0.260 | 台账 1-3] tab 行常驻：数据未就绪（groups 为空，
  /// 如加载失败）时回落单一「全部」tab（对标参考空态截图 03）；
  /// 选中态与切换经 [BookshelfNotifier.selectGroup] 持久化并真正过滤列表
  /// （[BookshelfStateGrouping.currentGroupBooks]）。
  ///
  /// [设置批6a-1] 可见分组 = `hideEmptyGroups` 过滤后的列表（「全部」
  /// 始终保留）；`shouldShowExpandButton` 在行尾追加组菜单按钮，切换时
  /// 映射回完整分组索引持久化。
  Widget _buildGroupTabBar(
      BuildContext context, WidgetRef ref, BookshelfState state,
      BookshelfSettings settings) {
    final groups = state.visibleGroups(hideEmpty: settings.hideEmptyGroups);
    final controller = _ensureTabController(groups.length);
    final selectedIndex = _visibleGroupIndex(state, groups);
    _syncTabControllerIndex(selectedIndex);
    final colorScheme = Theme.of(context).colorScheme;
    // [LAYOUT_MOTION_AUDIT L3] Tab 文案走 labelLargeEmphasized（M3 labelLarge + Medium 强调）
    final labelStyle = Theme.of(context)
        .textTheme
        .labelLarge
        ?.copyWith(fontWeight: FontWeight.w500);
    // [parity C3 B1] 分组 tab 单组左对齐：根因——SliverAppBar.large 的 bottom 槽
    // 以「松约束」下发，M3 可滚动 TabBar 在松约束下收缩为内容宽度并被父级
    // 居中（单组「全部」时整行偏右，多组时首 tab 同样不贴左）。包一层
    // SizedBox(width: double.infinity) 把 TabBar 撑满 bottom 槽宽度后，
    // isScrollable + TabAlignment.start 才能真正把首 tab 钉在左缘。
    final tabBar = TabBar(
      controller: controller,
      isScrollable: true, // 原版 tabMode = MODE_SCROLLABLE
      tabAlignment: TabAlignment.start,
      // [parity fix 2.0.264 补修 | 台账 1-3] tab 行左缘 20dp：参考 03b 首
      // tab 墨迹 x≈59px@3x≈20dp（复审量测），此前 edgePadding 0 钉屏左缘
      // （实测 x≈2px）贴死；可滚动 TabBar 下 padding 仅作用于首尾两 tab
      // 边缘，故只加 left 不影响尾 tab
      padding: const EdgeInsets.only(left: 20),
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
    final showMoreGroups =
        settings.shouldShowExpandButton && groups.length > 1;
    return SizedBox(
      width: double.infinity,
      child: Row(
        children: [
          Expanded(child: tabBar),
          if (showMoreGroups)
            IconButton(
              key: const ValueKey('bookshelf_group_menu_button'),
              icon: const Icon(Symbols.format_list_bulleted_rounded),
              tooltip: '分组菜单',
              onPressed: () => _showGroupMenu(context, ref, groups),
            ),
        ],
      ),
    );
  }

  /// 当前选中分组在可见列表中的索引（不可见时回退 0 = 全部）
  int _visibleGroupIndex(BookshelfState state, List<BookGroup> groups) {
    final selectedId = state.selectedGroup?.groupId;
    if (selectedId == null) return 0;
    final index = groups.indexWhere((g) => g.groupId == selectedId);
    return index < 0 ? 0 : index;
  }

  /// 分组选择菜单（style 1 顶部组菜单 / `shouldShowExpandButton` 行尾按钮）
  Future<void> _showGroupMenu(BuildContext context, WidgetRef ref,
      List<BookGroup> groups) async {
    final state = ref.read(bookshelfNotifierProvider);
    final selectedId = state.selectedGroup?.groupId;
    final picked = await showModalBottomSheet<BookGroup>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('选择分组',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final group in groups)
              ListTile(
                title: Text(group.groupName),
                trailing: group.groupId == selectedId
                    ? Icon(Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(sheetContext, group),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final index =
        state.groups.indexWhere((g) => g.groupId == picked.groupId);
    if (index >= 0) {
      await ref.read(bookshelfNotifierProvider.notifier).selectGroup(index);
    }
  }

  List<Widget> _buildAppBarActions(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(bookshelfSettingsProvider);
    return [
      // [设置批6a-1] 更新全部进行中的待更新数量（参考版 showWaitUpCount）
      if (settings.showWaitUpCount)
        ValueListenableBuilder<int>(
          valueListenable: _waitUpCount,
          builder: (context, count, _) {
            if (count <= 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Text(
                  '待更新 $count',
                  key: const ValueKey('bookshelf_wait_up_count'),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            );
          },
        ),
      // [UI-fix v2.0.175] 恢复搜索图标（原版 main_bookshelf.xml actionbar
      // 自带搜索项，红线对齐；Dynamic 搜索行双入口并存——用户报障找不到搜索）
      IconButton(
        icon: const Icon(Symbols.search_rounded),
        tooltip: AppStrings.search,
        onPressed: () => Navigator.pushNamed(context, AppRoutes.search),
      ),
      // 原版 main_bookshelf.xml 无常驻视图切换按钮，网格/列表切换在溢出菜单「布局设置」
      // [parity C3 B2] 触发钮为裸 ⋮ 图标（对齐参考 03b 顶栏 ⋮ 位置，无圆底）；
      // 菜单本体由自绘「图标+分体圆角卡」页面承接（_showCardMenu），
      // 替换原 PopupMenuButton 下拉形态（台账 1-4①：参考每项带图标+分体圆角卡）
      IconButton(
        icon: const Icon(Symbols.more_vert_rounded),
        tooltip: '更多',
        onPressed: () => _showCardMenu(context, ref),
      ),
    ];
  }

  // ===== [parity C3 B2] 自绘「图标+圆角卡」溢出菜单 =====
  //
  // [P2-31] 形态对齐参考版（RoundDropdownMenu 非 Miuix 分支：M3
  // DropdownMenu shape=medium / shadowElevation 4 / surfaceContainerLow）——
  // 由「全屏不透明白底 + 右侧竖板」改为「浮层」：
  // · 背景书架内容保持可见（route opaque=false）；
  // · 半透明 scrim（_kMenuScrimColor，alpha≈0.25）压暗整屏，点按关闭；
  // · 右侧一枚圆角 16 + 阴影浮卡（surfaceContainerLow）承载菜单项，
  //   高度受限可滚动；卡内 24dp 图标（onSurface）距左 15dp + 14sp 标签。
  // 首屏 11 项顺序/文案/功能项不动（台账 1-4），图标逐项对齐参考版
  // （见 _cardMenuItems [P2-31] 注），我方特有项保留（双基准原则）。

  List<_CardMenuItem> _cardMenuItems(WidgetRef ref) {
    final state = ref.read(bookshelfNotifierProvider);
    return [
      // [UI-parity 2.0.257] 首屏 11 项对齐参考版书架溢出菜单顺序
      // （远程书籍/添加本地/更新目录/布局设置/分组管理/添加网址/
      // 选择模式/书架管理/导出书单/导入书单/日志），使「导出书单/导入
      // 书单/日志」首屏可见（此前 14 项+4 分割线把三项挤到滚动区外，
      // 台账 1-4② 误判为功能缺失）
      // [parity C3 B3] 文案对齐参考版：「添加远程书籍」→「远程书籍」、
      // 「书架布局」→「布局设置」
      // [P2-31] 图标逐项对齐参考版 BookshelfScreen 溢出菜单
      // （Wifi/Save/Refresh/GridView/ViewCarousel/Link/Edit/Bookmarks/
      // UploadFile/CloudDownload/History → 映射 material_symbols rounded）
      _CardMenuItem('remote', '远程书籍', Symbols.wifi_rounded),
      _CardMenuItem('import', AppStrings.addLocalBook, Symbols.save_rounded),
      _CardMenuItem('update_all', AppStrings.updateAll, Symbols.refresh_rounded),
      _CardMenuItem('layout', '布局设置', Symbols.grid_view_rounded),
      _CardMenuItem('groups', '分组管理', Symbols.view_carousel_rounded),
      _CardMenuItem('add_url', '添加网址', Symbols.link_rounded),
      _CardMenuItem('select_mode', '选择模式', Symbols.edit_rounded),
      _CardMenuItem('manage', AppStrings.manageBookshelf, Symbols.bookmarks_rounded),
      _CardMenuItem('export_list', '导出书单', Symbols.upload_file_rounded),
      _CardMenuItem('import_list', '导入书单', Symbols.cloud_download_rounded),
      _CardMenuItem('log', '日志', Symbols.history_rounded),
      // 我方特有项（双基准原则保留不删）：离线缓存（对应原版
      // menu_download 缓存/导出）+ 分组展示模式 + 书源管理
      _CardMenuItem('offline_cache', '离线缓存', Symbols.wifi_off_rounded),
      // 分组模式三项：图标列用单选钮勾选态（对标原 _buildGroupModeItem 语义）
      _CardMenuItem(
          'group_none', '不分组',
          _radioIcon(state.groupMode == GroupMode.none)),
      _CardMenuItem(
          'group_source', '按来源分组',
          _radioIcon(state.groupMode == GroupMode.bySource)),
      _CardMenuItem(
          'group_group', '按分组显示',
          _radioIcon(state.groupMode == GroupMode.byGroup)),
      _CardMenuItem('sources', AppStrings.sourceManagement, Symbols.database_rounded),
    ];
  }

  /// 打开自绘卡菜单页（全屏 route）；返回被点选 action 后统一分发
  Future<void> _showCardMenu(BuildContext context, WidgetRef ref) async {
    final action = await Navigator.push<String>(
      context,
      _CardMenuRoute(_buildCardMenuPage(context, ref)),
    );
    if (action == null || !context.mounted) return;
    _handleMenuAction(context, ref, action);
  }

  /// [P2-31] 菜单页：参考版浮层形态——
  /// 背景书架内容保持可见（route opaque=false），半透明 scrim 压暗整屏，
  /// 右侧一枚圆角阴影浮卡承载菜单项（对标参考 RoundDropdownMenu 非 Miuix
  /// 分支：M3 DropdownMenu shape=medium / shadowElevation 4 /
  /// surfaceContainerLow），点 scrim 关闭。11 项功能行为不变。
  Widget _buildCardMenuPage(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final items = _cardMenuItems(ref);
    final cardColor = colorScheme.surfaceContainerLow; // 浮卡（近白）
    final onSurface = colorScheme.onSurface;

    Widget buildCard(int index, _CardMenuItem item) {
      // 浮卡内条目：透明行（浮卡统一底色），段间以加宽间距分隔
      final isSectionBreak = _isSectionBreak(items, index);
      return Padding(
        padding: EdgeInsets.only(
          top: index == 0 ? 8 : (isSectionBreak ? 16 : 4),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.pop(context, item.action),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                // 图标列：距卡左 15dp、宽 24dp（量测 15..33dp）
                Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Icon(item.icon, size: 24, color: onSurface),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 14,
                      color: onSurface,
                      fontWeight: FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        // [P2-31] 半透明 scrim：压暗后方书架（内容仍可见），点按关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(context),
            child: ColoredBox(
              // [P2-31] 稳定键值（widget 测试以同名字面量断言 scrim 存在；
              // 不导出命名常量，保证修复前测试亦可编译 → 干净红→绿）
              key: const ValueKey<String>('bookshelf_menu_scrim'),
              color: _kMenuScrimColor,
            ),
          ),
        ),
        // [P2-31] 右侧浮卡：圆角 16 + 阴影（对标参考 surfaceContainerLow
        // 卡 + shadowElevation 4），高度受限可滚动
        LayoutBuilder(
          builder: (context, constraints) {
            final maxCardHeight = constraints.maxHeight * 0.7;
            return Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxCardHeight),
                  // Material 提供浮卡底色 + 圆角 + 落影（elevation 4 对标
                  // 参考 shadowElevation 4），并为卡内 InkWell 提供 Material
                  // 祖先（ink 涟漪画布）
                  child: Material(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(16),
                    elevation: 4,
                    child: SizedBox(
                      width: 232,
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 8,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, i) => buildCard(i, items[i]),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// 分组模式项的单选钮图标（checked=当前选中模式）
  static IconData _radioIcon(bool checked) =>
      checked ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded;

  /// 原分割线位置（首屏 11 项后 / 分组模式三项后）→ 卡间 16dp 加宽
  /// （卡片分体形态下以间距替代 PopupMenuDivider）
  static bool _isSectionBreak(List<_CardMenuItem> items, int index) =>
      index == 12 || index == 16;

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookshelfNotifierProvider);
    final settings = ref.watch(bookshelfSettingsProvider);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final isGridMode = settings.layoutModeFor(isLandscape: isLandscape) == 1;
    // [审查 P1-2] 手动排序依赖 SliverReorderableList；网格模式无重排入口，
    // 显式临时切换为列表并展示提示，避免「能选手动排序但无法拖动」。
    final manualGridFallback =
        settings.bookshelfSort == BookshelfSortMode.manual && isGridMode;
    final effectiveGridMode = isGridMode && !manualGridFallback;

    // 可见分组（隐藏空分组；「全部」始终保留）
    final visibleGroups =
        state.visibleGroups(hideEmpty: settings.hideEmptyGroups);
    final selectedVisibleIndex = _visibleGroupIndex(state, visibleGroups);
    final effectiveGroup = visibleGroups[selectedVisibleIndex];
    // 选中组被「隐藏空分组」隐藏时，帧后回写「全部」保持数据源一致
    if (effectiveGroup.groupId != state.selectedGroup?.groupId &&
        _pendingVisibleGroupId != effectiveGroup.groupId) {
      _pendingVisibleGroupId = effectiveGroup.groupId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = ref.read(bookshelfNotifierProvider);
        final index = current.groups
            .indexWhere((g) => g.groupId == effectiveGroup.groupId);
        if (index >= 0) {
          ref.read(bookshelfNotifierProvider.notifier).selectGroup(index);
        }
        _pendingVisibleGroupId = null;
      });
    }
    final shelfBooks = sortBookshelfBooks(
      state.booksInGroup(effectiveGroup),
      sort: settings.bookshelfSort,
      sortOrder: settings.bookshelfSortOrder,
    );
    final isEmpty = shelfBooks.isEmpty && !state.isLoading;

    if (state.isLoading && state.books.isEmpty) {
      // [LAYOUT_PLAN P4] 首屏 Skeleton 接线：按当前布局模式渲染网格/列表骨架
      if (effectiveGridMode) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final metrics = _gridMetrics(
              context,
              settings: settings,
              books: state.books,
              viewportWidth: constraints.maxWidth,
              hasTagRow: false,
            );
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: metrics.columns,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: metrics.aspectRatio,
              ),
              itemCount: math.max(6, metrics.columns * 2),
              itemBuilder: (_, _) => GridSkeletonItem(
                // 紧凑/仅封面样式不渲染底部书名骨架，避免窄 cell 溢出
                showText: settings.bookshelfGridLayout == 0,
              ),
            );
          },
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

    if (isEmpty) {
      // [骨架对齐 2.0.260 | 台账 1-3] 空态对齐参考 03 截图：大标题「书架」
      // + 分组 tab 行常驻，正文区居中颜文字彩蛋（kaomoji 模式为 2026-08-29
      // 用户授权彩蛋，点击换颜文字）
      return CustomScrollView(
        slivers: [
          _buildHeaderSliver(context, ref, state, settings),
          // [设置批6a-1] 分组样式 1 隐藏 TabBar：空分组/空书架也保留顶部
          // 组标题与组菜单，避免无法切换分组
          if (settings.bookGroupStyle == 1)
            _buildGroupStyleHeader(
              context,
              ref,
              settings,
              visibleGroups,
              effectiveGroup,
            ),
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
      // [设置批6a-1] LayoutBuilder 取视口实际宽度：网格/多列列表按
      // 列数与封面宽动态计算 cell aspect
      child: LayoutBuilder(
        builder: (layoutContext, layoutConstraints) {
          final viewportWidth = layoutConstraints.maxWidth;
          final slivers = <Widget>[
            // [骨架对齐 2.0.260 | 台账 1-3] 头部 = 可折叠大标题「书架」 +
            // 分组 tab 行（bottom）；style 1 改为顶部组标题 + 组菜单
            _buildHeaderSliver(context, ref, state, settings),
            if (settings.bookGroupStyle == 1)
              _buildGroupStyleHeader(
                context,
                ref,
                settings,
                visibleGroups,
                effectiveGroup,
              ),
            // [UI-fix 2.0.258] 批量模式摘要卡位于头部之后（对齐参考版：
            // 标题/Tab →「已选N本 · 共M本」胶囊 → 书列表）
            if (state.isBatchMode)
              SliverToBoxAdapter(
                child: _buildBatchSummaryCard(context, ref, state),
              ),
            if (manualGridFallback)
              SliverToBoxAdapter(
                child: _buildManualSortListNotice(context),
              ),
            // 分组模式：渲染分组头 + 分组内容
            if (state.groupMode != GroupMode.none)
              ..._buildGroupedSlivers(
                  context, ref, state, settings, shelfBooks, viewportWidth)
            else if (effectiveGridMode)
              _buildGridSliver(context, ref, state, settings, shelfBooks,
                  viewportWidth)
            else if (settings.bookshelfSort == BookshelfSortMode.manual)
              _buildReorderableSliver(
                  context, ref, state, settings, shelfBooks)
            else
              _buildListSliver(context, ref, state, settings, shelfBooks,
                  viewportWidth),
            // [UI_SYNC_REFACTOR T3] 底部批量工具条（batch 模式且选中时显示）
            if (state.isBatchMode && state.selectedUrls.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildBatchBottomBar(context, ref, state),
              ),
          ];
          final scrollView = CustomScrollView(
            controller: _scrollController,
            slivers: slivers,
          );
          // [设置批6a-1] 快速滚动条（复用 Md3FastScroller，默认关）
          if (!settings.showBookshelfFastScroller) return scrollView;
          return Md3FastScroller(
            controller: _scrollController,
            child: scrollView,
          );
        },
      ),
    );
  }

  /// 上次「选中组被隐藏」的帧后回写目标（避免每帧重复调度）
  int? _pendingVisibleGroupId;

  /// [骨架对齐 2.0.260 | 台账 1-3] 头部 sliver：可折叠 LargeTitle「书架」
  /// + 常驻分组 tab 行（bottom，style 0）。空态/内容态共用。
  ///
  /// [设置批6a-1] 分组样式 1 隐藏 TabBar（顶部组标题 + 组菜单替代），
  /// 展开高度同步减去 TabBar 56dp。
  Widget _buildHeaderSliver(BuildContext context, WidgetRef ref,
      BookshelfState state, BookshelfSettings settings) {
    final showTabs = settings.bookGroupStyle != 1;
    return LegadoTabRootHeaderSliver(
      large: true,
      // [骨架对齐 2.0.260 | 台账 1-3] 大标题 28sp：参考 03b 截图量测字高
      // 79px（480dpi 下 ≈28sp，与首页 2.0.259 大标题先例一致）
      largeTitleFontSize: 28,
      // [骨架对齐 2.0.260 | 台账 1-3] 展开态 164dp = 顶行 64 + 标题区 44 +
      // TabBar 56（对齐参考 03b 量测 188dp - 状态栏 24）；style 1 无 TabBar
      // 时收敛为 108dp（64 + 44），保持同一标题带节距。
      expandedHeight: showTabs ? 164 : 108,
      title: Text(AppStrings.bookshelf),
      // [UI-fix 2.0.258] 选择模式顶栏切换为批量动作集（全选/反选/删除/取消）
      actions: state.isBatchMode
          ? _buildBatchAppBarActions(context, ref)
          : _buildAppBarActions(context, ref),
      // 分组 tab 行（TabBar 默认高 kToolbarHeight，Tab 高度 40dp）
      bottom: showTabs
          ? PreferredSize(
              preferredSize: const Size.fromHeight(kToolbarHeight),
              child: _buildGroupTabBar(context, ref, state, settings),
            )
          : null,
      // [parity C3 B5] 书架顶栏钮按参考锁裸图标（03/03b 顶栏 🔍/⋮ 无
      // 圆底；选择模式 05 批量钮同为裸图标），不随全局 topBarButtonStyle
      // 档位（全局档位仍作用于搜索等圆底屏）
      actionsStyle: TopBarButtonStyle.plain,
    );
  }

  /// 手动排序 + 网格布局：显式提示已临时切换为列表（审查 P1-2）
  Widget _buildManualSortListNotice(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('bookshelf_manual_sort_notice'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.drag_indicator_rounded,
              size: 20, color: cs.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '手动排序需使用列表布局，已临时切换为列表',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSecondaryContainer,
                  ),
            ),
          ),
          TextButton(
            onPressed: () => showBookshelfConfigSheet(
              context,
              viewportWidth: _lastViewportWidth,
            ),
            child: const Text('布局设置'),
          ),
        ],
      ),
    );
  }

  /// 分组样式 1：顶部组标题 + 组菜单（可横向 chip/下拉；此处用组菜单）
  Widget _buildGroupStyleHeader(
    BuildContext context,
    WidgetRef ref,
    BookshelfSettings settings,
    List<BookGroup> visibleGroups,
    BookGroup current,
  ) {
    final theme = Theme.of(context);
    final count = visibleGroups.length;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                current.groupName,
                key: const ValueKey('bookshelf_group_style_title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (count > 1)
              IconButton(
                key: const ValueKey('bookshelf_group_style_menu'),
                icon: const Icon(Symbols.format_list_bulleted_rounded),
                tooltip: '分组菜单',
                onPressed: () =>
                    _showGroupMenu(context, ref, visibleGroups),
              ),
          ],
        ),
      ),
    );
  }

  /// 网格布局度量（列数 / 单格宽高比 / 封面宽 / 单格高）
  ///
  /// [设置批6a-1] 对齐参考版 `BookshelfScreen.kt:1372-1400`：
  /// - 列数按横竖屏各一套（默认竖屏 3 / 横屏 7）；
  /// - 内容左右边距 8、列间距 8（参考 `adaptiveContentPaddingBookshelf`
  ///   与 `Arrangement.spacedBy(8.dp)`）；
  /// - 封面宽取 `min(bookshelfGridCoverWidth, cellWidth)`（默认 120），
  ///   宽屏下封面固定宽居中，窄屏下铺满列宽；
  /// - 单格高 = 封面高（按当前封面比例）+ 书名区 + 标签行。
  ({int columns, double aspectRatio, double coverWidth, double cellHeight})
      _gridMetrics(
    BuildContext context, {
    required BookshelfSettings settings,
    required List<Book> books,
    required double viewportWidth,
    required bool hasTagRow,
  }) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final columns =
        math.max(1, settings.gridColumnsFor(isLandscape: isLandscape));
    const padding = 8.0;
    const spacing = 8.0;
    final availableWidth = math.max(0.0, viewportWidth - padding * 2);
    final cellWidth = math.max(
      1.0,
      (availableWidth - spacing * (columns - 1)) / columns,
    );
    final coverWidth = math.min(
      settings.bookshelfGridCoverWidth.toDouble(),
      cellWidth,
    );
    final coverRatio = _shelfCoverRatio(books);
    final coverHeight =
        coverWidth / (coverRatio <= 0 ? (5 / 7) : coverRatio);
    final titleHeight = settings.bookshelfGridLayout == 0
        ? BookGridItem.titleAreaHeightFor(
            context,
            maxLines: settings.bookshelfTitleMaxLines,
            smallFont: settings.bookshelfTitleSmallFont,
          )
        : 0.0;
    final tagHeight = hasTagRow
        ? BookDisplayTagsRow.heightFor(
            context,
            compact: true,
            minHeight: BookGridItem.tagRowHeight,
          )
        : 0.0;
    final cellHeight = coverHeight + titleHeight + tagHeight;
    return (
      columns: columns,
      aspectRatio: cellWidth / math.max(1.0, cellHeight),
      coverWidth: coverWidth,
      cellHeight: cellHeight,
    );
  }

  Widget _buildGridSliver(
    BuildContext context,
    WidgetRef ref,
    BookshelfState state,
    BookshelfSettings settings,
    List<Book> books,
    double viewportWidth,
  ) {
    // [设置批6a-1] 标签行按「当前网格内是否有任一本书带标签」预留高度：
    // 无标签时不改变既有 cell 比例（封面 5:7 不被挤压）
    final hasTagRow = settings.bookshelfShowTag &&
        settings.bookshelfGridLayout != 2 &&
        books.any((b) => state.displayTagsOf(b, showTag: settings.bookshelfShowTag).isNotEmpty);
    final metrics = _gridMetrics(
      context,
      settings: settings,
      books: books,
      viewportWidth: viewportWidth,
      hasTagRow: hasTagRow,
    );
    return SliverPadding(
      // 参考版内容边距 8 + 列间距 8（BookshelfScreen.kt:1400-1410）
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: metrics.columns,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: metrics.aspectRatio,
        ),
        itemCount: books.length,
        itemBuilder: (context, index) {
          final book = books[index];
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: metrics.coverWidth,
              height: metrics.cellHeight,
              child: _buildGridItem(
                context,
                ref,
                state,
                settings,
                book,
                state.displayTagsOf(book, showTag: settings.bookshelfShowTag),
                hasTagRow,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 书架网格封面宽高比（批39：限制比例开 = 固定 5:7；关 = 首个已解析
  /// 原图比例）
  ///
  /// [批39 审查回修] 骨架与正式网格共用本方法，避免两处各写一份口径
  /// 漂移（骨架首屏 → 内容行高跳变）。
  double _shelfCoverRatio(Iterable<Book> books) {
    if (uiSettingsListenable.value.restrictCoverRatio) return 5 / 7;
    return CoverAspectRatio.representativeRatio(
      books.map((b) => b.customCoverUrl ?? b.coverUrl),
    );
  }

  /// 拖拽排序列表（仅「手动排序」模式调用；其它模式走普通 SliverList）
  Widget _buildReorderableSliver(
    BuildContext context,
    WidgetRef ref,
    BookshelfState state,
    BookshelfSettings settings,
    List<Book> shelfBooks,
  ) {
    final descending =
        settings.bookshelfSortOrder == BookshelfSortOrder.descending;
    return SliverReorderableList(
      itemCount: shelfBooks.length,
      // `onReorderItem` 的 newIndex 已按移除项调整，直接作为最终插入索引
      onReorderItem: (oldIndex, newIndex) async {
        final reordered = List<Book>.from(shelfBooks);
        final book = reordered.removeAt(oldIndex);
        reordered.insert(newIndex, book);
        await ref
            .read(bookshelfNotifierProvider.notifier)
            .saveBookOrder(reordered, descending: descending);
      },
      itemBuilder: (context, index) {
        final book = shelfBooks[index];
        // [UI_SYNC_REFACTOR T3] 批量模式点击 = 切换选中
        final batch = ref.watch(bookshelfNotifierProvider
            .select((s) => s.isBatchMode));
        final Widget child;
        if (batch) {
          final selected = ref.watch(bookshelfNotifierProvider
              .select((s) => s.selectedUrls.contains(book.bookUrl)));
          child = _buildBatchListItem(
              context, ref, state, settings, book, selected);
        } else {
          child = BookListItem(
            book: book,
            settings: settings,
            tags:
                state.displayTagsOf(book, showTag: settings.bookshelfShowTag),
            typeLabel: _bookTypeLabel(settings, book),
            onTap: () => _openBook(context, ref, book),
            // [审查 P1-2] 手动排序时长按用于拖拽，不再打开书籍信息；
            // 信息入口仍可通过点击封面进入详情页后长按/菜单访问。
            onLongPress: null,
          );
        }
        // SDK 要求调用方为每个 item 包 ReorderableDelayedDragStartListener
        // 并提供 key；否则拖拽手势永远不会触发 onReorderItem。
        return ReorderableDelayedDragStartListener(
          key: ValueKey(book.bookUrl),
          index: index,
          enabled: !batch,
          child: child,
        );
      },
    );
  }

  Widget _buildGridItem(
    BuildContext context,
    WidgetRef ref,
    BookshelfState state,
    BookshelfSettings settings,
    Book book,
    List<String> tags,
    bool reserveTagRow,
  ) {
    // [UI_SYNC_REFACTOR T3] 批量模式点击 = 切换选中
    final batch = ref.watch(bookshelfNotifierProvider
        .select((s) => s.isBatchMode));
    if (batch) {
      return _buildBatchGridItem(
          context, ref, settings, book, tags, reserveTagRow);
    }
    // 稳定 ValueKey（bookUrl）避免数据变化时整网格重建；RepaintBoundary 隔离重绘区域
    final item = BookGridItem(
      key: ValueKey(book.bookUrl),
      title: book.name,
      coverUrl: book.customCoverUrl ?? book.coverUrl,
      sourceOrigin: book.origin,
      tags: tags,
      reserveTagRow: reserveTagRow,
      gridStyle: settings.bookshelfGridLayout,
      titleSmallFont: settings.bookshelfTitleSmallFont,
      titleCenter: settings.bookshelfTitleCenter,
      titleMaxLines: settings.bookshelfTitleMaxLines,
      coverShadow: settings.bookshelfCoverShadow,
      unreadNum:
          settings.showUnread ? unreadChapterNum(book) : 0,
      showNewBadge: settings.showUnread &&
          settings.showUnreadNew &&
          book.lastCheckCount > 0,
      typeLabel: _bookTypeLabel(settings, book),
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

  /// 书籍类型标签（仅 `showTip` 开启；取值顺序对齐参考 BookItem.kt:655）
  String? _bookTypeLabel(BookshelfSettings settings, Book book) {
    if (!settings.showTip) return null;
    if ((book.bookType & BookType.audio) != 0) return '音频';
    if ((book.bookType & BookType.image) != 0) return '漫画';
    if ((book.bookType & BookType.webFile) != 0) return '文件';
    if (BookType.isLocalBook(book)) return '本地';
    return '小说';
  }

  /// 列表展示（1 列走自然高度 SliverList；2–5 列走 SliverGrid）
  Widget _buildListSliver(
    BuildContext context,
    WidgetRef ref,
    BookshelfState state,
    BookshelfSettings settings,
    List<Book> books,
    double viewportWidth,
  ) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final configuredColumns =
        math.max(1, settings.listColumnsFor(isLandscape: isLandscape));
    // [审查 P1-1] 入口按最小可读 cell 宽（150dp）夹取实际列数：
    // 360/400dp 屏配置 3–5 列会收敛为 2 列，避免未读角标/摘要行横向溢出。
    final columns = math.min(
      configuredColumns,
      BookshelfSettings.maxReadableListColumns(viewportWidth),
    );
    if (columns <= 1) {
      return SliverList.builder(
        itemCount: books.length,
        itemBuilder: (context, index) {
          final book = books[index];
          final batch = ref.watch(bookshelfNotifierProvider
              .select((s) => s.isBatchMode));
          if (batch) {
            final selected = ref.watch(bookshelfNotifierProvider
                .select((s) => s.selectedUrls.contains(book.bookUrl)));
            return _buildBatchListItem(
                context, ref, state, settings, book, selected);
          }
          return BookListItem(
            key: ValueKey(book.bookUrl),
            book: book,
            settings: settings,
            tags: state.displayTagsOf(book, showTag: settings.bookshelfShowTag),
            typeLabel: _bookTypeLabel(settings, book),
            onTap: () => _openBook(context, ref, book),
            onLongPress: () => _openBookInfo(context, book),
          );
        },
      );
    }
    return _buildMultiColumnListSliver(
        context, ref, state, settings, books, viewportWidth, columns);
  }

  /// 多列列表（设置批6a-1：列表列数 1–5，SliverGrid 承载列表行）
  ///
  /// Flutter `SliverGrid` 需要固定 childAspectRatio，故按当前设置估算
  /// 「封面高 / 标题行 / 简介行」的最大行高；多列时封面宽度按列宽 45%
  /// 限制（参考版 Row 布局在窄列下等价表现）并限制简介最多 3 行，
  /// 避免固定格高裁切。
  Widget _buildMultiColumnListSliver(
    BuildContext context,
    WidgetRef ref,
    BookshelfState state,
    BookshelfSettings settings,
    List<Book> books,
    double viewportWidth,
    int columns,
  ) {
    const padding = 8.0;
    const spacing = 8.0;
    final availableWidth = math.max(0.0, viewportWidth - padding * 2);
    final cellWidth = math.max(
      1.0,
      (availableWidth - spacing * (columns - 1)) / columns,
    );
    final coverWidth =
        math.min(settings.bookshelfListCoverWidth.toDouble(), cellWidth * 0.42);
    final coverHeight = BookListItem.coverHeightFor(coverWidth);
    final scaler = MediaQuery.textScalerOf(context);
    final compact = settings.bookshelfLayoutCompact;
    final showMore = settings.showBookIntro && !compact;
    final hasTags = !compact &&
        settings.showBookIntro &&
        settings.bookshelfShowTag &&
        books.any((b) => state.displayTagsOf(b, showTag: settings.bookshelfShowTag).isNotEmpty);
    final introLines = settings.bookshelfIntroMaxLines == 0
        ? 3
        : math.min(settings.bookshelfIntroMaxLines, 3);
    final titleHeight =
        scaler.scale(16) * 1.25 * settings.bookshelfTitleMaxLines + 4;
    final authorHeight = math.max(17.0, scaler.scale(13) * 1.3);
    final descHeight =
        (!compact && books.any((b) => (b.durChapterTitle ?? '').isNotEmpty))
            ? authorHeight
            : 0.0;
    final tagsHeight = hasTags
        ? BookDisplayTagsRow.heightFor(context, minHeight: 20)
        : 0.0;
    final introHeight = showMore && settings.bookshelfShowIntro
        ? scaler.scale(12) * 1.35 * introLines + 4
        : 0.0;
    final latestHeight = showMore &&
            settings.bookshelfShowLatestChapter &&
            books.any((b) => (b.latestChapterTitle ?? '').isNotEmpty)
        ? authorHeight
        : 0.0;
    final progressHeight =
        books.any((b) => bookReadProgress(b) != null) ? 6.0 : 0.0;
    // 内容列高 + 行上下 12×2 内边距 + 0.5 分隔线 + 文字行高安全余量
    // （固定格高无法按真实排版回流；实测 1.3 倍字号下 Text 行距比估算
    // 多约 11dp，按 textScaler 补 14dp 余量，1.6 倍字号同样不裁切）
    final contentHeight = titleHeight +
        authorHeight +
        descHeight +
        tagsHeight +
        introHeight +
        latestHeight +
        progressHeight +
        24 +
        0.5 +
        scaler.scale(14);
    final cellHeight = math.max(coverHeight + 24 + 0.5, contentHeight);
    final aspectRatio = cellWidth / math.max(1.0, cellHeight);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: aspectRatio,
        ),
        itemCount: books.length,
        itemBuilder: (context, index) {
          final book = books[index];
          final batch = ref.watch(bookshelfNotifierProvider
              .select((s) => s.isBatchMode));
          if (batch) {
            final selected = ref.watch(bookshelfNotifierProvider
                .select((s) => s.selectedUrls.contains(book.bookUrl)));
            return _buildBatchListItem(context, ref, state, settings, book,
                selected,
                maxCoverWidth: coverWidth);
          }
          return BookListItem(
            key: ValueKey(book.bookUrl),
            book: book,
            settings: settings,
            tags: state.displayTagsOf(book, showTag: settings.bookshelfShowTag),
            typeLabel: _bookTypeLabel(settings, book),
            maxCoverWidth: coverWidth,
            introMaxLinesOverride: introLines,
            onTap: () => _openBook(context, ref, book),
            onLongPress: () => _openBookInfo(context, book),
          );
        },
      ),
    );
  }

  // ===== 操作 =====

  /// 对标原版 startActivityForBook：未读进书详页 + 立即自动开读（A4 对齐 B）；
  /// 已读按 BookType 分流到 video / audio / reader-comic / reader
  /// （勿固定文本阅读器）。— Reasonix + UI
  Future<void> _openBook(
      BuildContext context, WidgetRef ref, Book book) async {
    if (book.durChapterIndex <= 0 && book.durChapterPos <= 0) {
      // [A4 对齐 B | 2026-09-21 裁决] 未读书单击 = 详情页 + 立即自动开读
      // （等价重构版 BookInfoPage(openReaderImmediately: true)）：详情页
      // 目录就绪即自动开读（未读书取首章）；目录不可用则停留详情页，仍可
      // 经「阅读」FAB 手动开读。长按入口走 _openBookInfo（同为右栏详情，
      // 只是不自动开读）。
      // [设置批2b-2c] 列表-详情：宽屏进右栏（左书架保持），窄屏/off root
      // 全屏；左列表选择替换旧右栏栈（replace）。await 至弹回书架（先关
      // 阅读器再关详情页）后单本定向刷新：未读链路返回时同步新进度。
      await pushMainDetailNamed(
        context,
        AppRoutes.bookInfo,
        arguments: BookInfoArgs(book: book, openReaderImmediately: true),
        replace: true,
        source: MainTab.bookshelf,
      );
      if (!context.mounted) return;
      await _refreshBookOnReturn(context, ref, book);
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
    // 批9a 项4：分流前刷新漫画浏览开关镜像（showMangaUi=false 时在线
    // 图片书回落文本阅读器）
    await BookOpenUtils.refreshShowMangaUi();
    if (!context.mounted) return;
    final route = BookOpenUtils.routeForTypeBits(
      typeBits,
      isLocalBook: BookType.isLocalBook(book),
    );
    // [设置批2b-2c 复核] 左列表选择已读书 A→B：阅读器是 standalone root
    // 页，先把旧右栏详情清空（关闭阅读器后回到空右栏）；await 期间切 Tab
    // 则放弃本次打开。
    if (!isMainDetailSourceCurrent(context, MainTab.bookshelf)) return;
    clearMainDetailPane(context);
    // 阅读器/漫画/音频/视频属 standalone，固定 root 全屏（书架本身在 root
    // PageView 内，此写法与原行为等价，仅显式化）。
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (BookOpenUtils.needsReaderNotifier(route)) {
      ref.read(readerNotifierProvider.notifier).openBook(bookToOpen);
      await rootNavigator.pushNamed(route);
    } else {
      await rootNavigator.pushNamed(
        route,
        arguments: BookOpenUtils.argumentsForRoute(route, bookToOpen),
      );
    }
    // [队列⑫ P3 | 2026-09-22] 弹回书架后单本定向刷新（进度同步）
    if (!context.mounted) return;
    await _refreshBookOnReturn(context, ref, book);
  }

  /// [队列⑫ P3 | 2026-09-22] 从阅读器/详情页返回书架：单本定向刷新
  ///
  /// 上方 `await Navigator.pushNamed` 在该路由被弹回（回到书架）时才返回，
  /// 此刻重拉该书最新进度写回内存（BookshelfNotifier.refreshBook），
  /// 「刚读完的书」进度行/进度条随返回同步。不做整页重建、不新增 UI；
  /// 书若在阅读期间被移除，notifier 内部回退全量 refresh 保持一致。
  Future<void> _refreshBookOnReturn(
      BuildContext context, WidgetRef ref, Book book) async {
    if (!context.mounted) return;
    await ref.read(bookshelfNotifierProvider.notifier).refreshBook(book.bookUrl);
  }

  /// 长按封面/书名直接打开书籍信息页（对齐安卓原版行为）
  ///
  /// [设置批2b-2c] 与单击同一列表-详情入口：宽屏进右栏（替换旧栈），
  /// 窄屏 root 全屏。
  void _openBookInfo(BuildContext context, Book book) {
    pushMainDetailNamed(
      context,
      AppRoutes.bookInfo,
      arguments: book,
      replace: true,
      source: MainTab.bookshelf,
    );
  }

  /// 选择本地书籍文件并导入书架
  Future<void> _addLocalBook(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(bookshelfNotifierProvider.notifier);
    final errorColor = Theme.of(context).colorScheme.error;

    // [iOS 视角F C2] file_picker 8.x 的 iOS 端对 FileType.custom 逐个把扩展名
    // 解析为 UTI（UTTypeCreatePreferredIdentifierForTag）：解析不到（mobi/umd
    // 未在 iOS 注册）的扩展名被静默跳过（仅 [Skipping type] 日志）→ 选择器
    // 实际只剩 epub/txt/pdf 可选，而 Rust 内核支持 MOBI 解析——收窄扩展名
    // 列表会让 iOS 丢失 Android 已有的 mobi 导入能力。故 iOS 回落
    // FileType.any（全部文件可选，不可导入的格式由下方失败 SnackBar 显式
    // 报告）；Android 保持 custom 列表过滤（列表内容见下方注释）。
    // 注意：file_picker 8.3.7 Dart 侧在 type != custom 且 allowedExtensions
    // 非空时抛 ArgumentError，any 分支不得传列表。
    //
    // [cbz P1-1 | 2026-10-03] Android 白名单与导入页 import_screen.dart 的
    // _supportedFormats **同序同集合**（epub/txt/mobi/azw3/azw/pdf/umd/cbz，
    // 两处需同步维护，互指注释）：
    // · cbz 为「整本导入」格式（Rust 按 LOCAL|image 图片漫画包处理，
    //   不解压），缺失则该格式在 Android file_picker（FileType.custom）
    //   经 MimeTypeMap 过滤后被 DocumentsUI 置灰、无法选择（P1-1 回归，
    //   真机验证：本机 MimeTypeMap 将 .cbz 映射为 application/x-cbz）；
    // · zip/rar/7z 为压缩包格式，走导入页解压导入链路（_archiveFormats），
    //   不属于整本导入白名单。
    final result = Platform.isIOS
        ? await FilePicker.platform.pickFiles(
            type: FileType.any, allowMultiple: true)
        : await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const [
              'epub',
              'txt',
              'mobi',
              'azw3',
              'azw',
              'pdf',
              'umd',
              'cbz',
            ],
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
      // [iOS 视角F C1] iOS file_picker Import 模式把文件「移动」到 tmp；
      // 此处拷入持久 Documents/books/ 并改存「相对 Documents 可迁移标识」，
      // 避免 tmp 清理 / 重签名（容器 UUID 变化）后本地书失效（读侧以当前
      // 容器路径重建）。非 iOS 平台保持原绝对路径不变（兼容存量）。
      String toImport = path;
      if (Platform.isIOS) {
        try {
          toImport = await LocalBookStore.store(path);
        } catch (e) {
          failures.add(file.name);
          if (failureDetails.length < 3) {
            failureDetails.add('${file.name}：本地书持久化失败（$e）');
          }
          continue;
        }
      }
      try {
        await notifier.importLocalBook(toImport);
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
    // [iOS 视角F C2] UI 提示：any 选择器下选到不可导入的扩展名时，
    // 显式说明「显示全部文件、仅电子书格式可导入」，避免静默困惑
    if (Platform.isIOS) {
      // 与上方 Android 白名单及 import_screen.dart::_supportedFormats
      // 同集合（azw3/azw 为 KF8 MOBI、cbz 为整本导入漫画包，均可导入）
      const importable = {
        'epub',
        'txt',
        'mobi',
        'azw3',
        'azw',
        'pdf',
        'umd',
        'cbz',
      };
      final pickedExts = result.files
          .map((f) => f.name.split('.').last.toLowerCase())
          .where((e) => e.isNotEmpty)
          .toSet();
      if (pickedExts.difference(importable).isNotEmpty) {
        messages.add(
            'iOS 选择器显示全部文件，仅电子书格式（epub/txt/mobi/azw3/azw/pdf/umd/cbz）可导入');
      }
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

  /// 构建分组 slivers：每组一个头部 + 网格/列表
  ///
  /// [设置批6a-1] 入参为当前分组按设置排序后的书籍；组内再各自排序
  /// （分组模式与排序正交），网格/列表与主列表共用同一套布局设置。
  List<Widget> _buildGroupedSlivers(
    BuildContext context,
    WidgetRef ref,
    BookshelfState state,
    BookshelfSettings settings,
    List<Book> books,
    double viewportWidth,
  ) {
    final groups = state.groupedBooksOf(books);
    // 手动排序在分组展示下无重排入口，统一走列表（网格模式主列表已提示）
    final isGridMode = settings.bookshelfSort != BookshelfSortMode.manual &&
        settings.layoutModeFor(
              isLandscape:
                  MediaQuery.orientationOf(context) == Orientation.landscape,
            ) ==
            1;
    final slivers = <Widget>[];
    for (final entry in groups.entries) {
      // 入参 books 已按设置排序；分组保持插入顺序，组内无需重复排序
      // （审查 P2：删除每组重复 pinyin 排序）。
      final sorted = entry.value;
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
                  '${sorted.length}',
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
      if (isGridMode) {
        slivers.add(_buildGridSliver(
            context, ref, state, settings, sorted, viewportWidth));
      } else {
        slivers.add(_buildListSliver(
            context, ref, state, settings, sorted, viewportWidth));
      }
    }
    return slivers;
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
        // [设置批6a-1] 布局设置升级为完整配置 Sheet（分组/排序/布局/
        // 角标/其他五段，对齐参考版 BookshelfConfigSheet）
        showBookshelfConfigSheet(
          context,
          viewportWidth: _lastViewportWidth,
        );
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

  /// 导出书单（批16e：接入统一导出目标 Sheet）
  ///
  /// 对齐原版 `BaseBookshelfFragment.kt:223-229`（menu_export_bookshelf →
  /// `exportBookshelf` → HandleFileContract.EXPORT）：内容为 JSON 数组
  /// `[{name,author,intro}]`（2 空格缩进，intro 取显示简介），文件名
  /// `bookshelf.json`、`application/json`。
  ///
  /// [批16e 回修 | P3-3] 简介回退对齐 Kotlin `Book.getDisplayIntro()`：
  /// `customIntro.isNullOrEmpty()` 时回退 `intro`，空串不再覆盖原始简介。
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
              'intro': _displayIntro(b),
            })
        .toList();
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final result = await showExportFileSheet(
      context,
      content: json,
      fileName: 'bookshelf.json',
      subject: '导出书单',
    );
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  /// 显示简介（对齐 Kotlin `Book.getDisplayIntro()`）：
  /// `customIntro` 为 null 或空串时回退 `intro`。
  String _displayIntro(Book book) {
    final custom = book.customIntro;
    if (custom == null || custom.isEmpty) return book.intro ?? '';
    return custom;
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 更新目录 / 添加网址 / 导入书单 — Qoder =====

  /// 更新全部书籍目录（对标 Kotlin updateAllBooks：仅刷新允许更新的非本地书）
  Future<void> _updateAllBooks() async {
    final api = ref.read(bookApiProvider);
    final settings = ref.read(bookshelfSettingsProvider);
    final books = sortBookshelfBooks(
      ref.read(bookshelfNotifierProvider).books,
      sort: settings.bookshelfSort,
      sortOrder: settings.bookshelfSortOrder,
    );
    var targets = books.where(BookType.canUpdateToc).toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有需要更新的书籍')),
      );
      return;
    }
    // [设置批6a-1] 更新数量限制（0 = 不限制；超出部分截断并提示）
    final totalTargets = targets.length;
    final limit = settings.bookshelfRefreshingLimit;
    final truncated = limit > 0 && targets.length > limit;
    if (truncated) {
      targets = targets.take(limit).toList();
    }
    final progress = ValueNotifier<String>('准备中...');
    if (mounted) _waitUpCount.value = targets.length;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (context, text, _) => AlertDialog(
          content: Row(
            children: [
              // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（线宽口径：保留
              // 2dp 实参；参考版主流默认 4dp 由封装默认承载）
              const SizedBox(
                width: 24,
                height: 24,
                child: AppCircularProgressIndicator(strokeWidth: 2),
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
      // 含当前这本在内的待更新数量（对齐参考版队列计数口径）
      if (mounted) _waitUpCount.value = targets.length - i;
      try {
        await api.refreshToc(book.bookUrl, book.origin);
        ok++;
      } catch (e) {
        debugPrint('更新目录失败《${book.name}》: $e');
      }
      if (!mounted) break;
    }
    if (mounted) _waitUpCount.value = 0;
    if (!mounted) {
      progress.dispose();
      return;
    }
    Navigator.pop(context); // 关闭进度对话框
    progress.dispose();
    ref.read(bookshelfNotifierProvider.notifier).refresh();
    final skipped = totalTargets - targets.length;
    final limitNote =
        truncated ? '，限制 $limit 本（已跳过 $skipped 本）' : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            '目录更新完成：成功 $ok/${targets.length} 本$limitNote'),
      ),
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
  Widget _buildBatchGridItem(
    BuildContext context,
    WidgetRef ref,
    BookshelfSettings settings,
    Book book,
    List<String> tags,
    bool reserveTagRow,
  ) {
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
                // [设置批6a-1] 与封面 4dp 圆角同口径
                borderRadius:
                    BorderRadius.circular(BookGridItem.coverCornerRadius),
              )
            : null,
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(BookGridItem.coverCornerRadius),
                child: BookGridItem(
                  key: ValueKey(book.bookUrl),
                  title: book.name,
                  coverUrl: book.customCoverUrl ?? book.coverUrl,
                  unreadNum:
                      settings.showUnread ? unreadChapterNum(book) : 0,
                  showNewBadge: settings.showUnread &&
                      settings.showUnreadNew &&
                      book.lastCheckCount > 0,
                  typeLabel: _bookTypeLabel(settings, book),
                  sourceOrigin: book.origin,
                  tags: tags,
                  reserveTagRow: reserveTagRow,
                  gridStyle: settings.bookshelfGridLayout,
                  titleSmallFont: settings.bookshelfTitleSmallFont,
                  titleCenter: settings.bookshelfTitleCenter,
                  titleMaxLines: settings.bookshelfTitleMaxLines,
                  coverShadow: settings.bookshelfCoverShadow,
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
    BuildContext context,
    WidgetRef ref,
    BookshelfState state,
    BookshelfSettings settings,
    Book book,
    bool selected, {
    double? maxCoverWidth,
  }) {
    final cs = Theme.of(context).colorScheme;
    final item = BookListItem(
      key: ValueKey(book.bookUrl),
      book: book,
      settings: settings,
      tags: state.displayTagsOf(book, showTag: settings.bookshelfShowTag),
      typeLabel: _bookTypeLabel(settings, book),
      maxCoverWidth: maxCoverWidth,
      introMaxLinesOverride: maxCoverWidth == null ? null : 3,
      onTap: () => ref
          .read(bookshelfNotifierProvider.notifier)
          .toggleSelect(book.bookUrl),
    );
    // [审查 P1-1] 多列批量：勾选图标叠放在**封面右上角**，不再占用 Row
    // 尾部 22+16dp；位置按实际封面宽计算（BookListItem 窄列 padding 4/8，
    // 封面起点 x=4、y=8，图标 22dp 内缩 4dp）。
    if (maxCoverWidth != null) {
      final coverWidth = math.min(
        settings.bookshelfListCoverWidth.toDouble(),
        maxCoverWidth,
      );
      final left = math.max(0.0, coverWidth - 22);
      return Material(
        key: ValueKey(book.bookUrl),
        color: selected
            ? cs.secondaryContainer.withValues(alpha: 0.3)
            : Colors.transparent,
        child: Stack(
          children: [
            item,
            Positioned(
              left: left,
              top: 12,
              // 图标只做展示，点击穿透到 BookListItem 的 InkWell 切换选中
              child: IgnorePointer(
                child: Container(
                  key: ValueKey('bookshelf-batch-check-${book.bookUrl}'),
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Material(
      key: ValueKey(book.bookUrl),
      color: selected
          ? cs.secondaryContainer.withValues(alpha: 0.3)
          : Colors.transparent,
      child: Row(
        children: [
          Expanded(child: item),
          GestureDetector(
            key: ValueKey('bookshelf-batch-check-${book.bookUrl}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => ref
                .read(bookshelfNotifierProvider.notifier)
                .toggleSelect(book.bookUrl),
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
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
                Flexible(
                  child: Text(
                    '已选 ${state.selectedUrls.length} 本',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Flexible(
                  child: Text(
                    ' · 共 ${state.currentGroupBooks.length} 本',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
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

/// [parity C3 B2] 自绘卡菜单条目（action + 文案 + 图标）
class _CardMenuItem {
  final String action;
  final String label;
  final IconData icon;

  const _CardMenuItem(this.action, this.label, this.icon);
}

/// [P2-31] 菜单页路由：整页淡入（浮层形态）。
/// [P2-31] opaque=false —— 背景书架内容保持可见（对标参考
/// RoundDropdownMenu 浮层，而非全屏不透明覆盖）；scrim + 浮卡见
/// _buildCardMenuPage。
class _CardMenuRoute extends PageRouteBuilder<String> {
  _CardMenuRoute(Widget page)
      : super(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 150),
          pageBuilder: (_, _, _) => page,
        );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(opacity: animation, child: child);
  }
}

/// [P2-31] 菜单 scrim 色（半透明压暗，书架内容仍透出）。
/// 半透明（alpha 0x40 ≈ 0.25）保证后方书架内容透出可见（浮层形态，
/// 而非修复前的全屏不透明白底）。
const Color _kMenuScrimColor = Color(0x40000000);
