/// 书源探索页面（ExploreScreen）
///
/// 参考 Android 原版 ExploreFragment.kt 实现
/// 核心功能：
/// 1. 显示已安装的书源列表
/// 2. 支持实时搜索过滤（300ms 防抖）
/// 3. 按分组筛选书源
/// 4. 一键安装/卸载书源（CRUD 操作）
/// 5. 点击分类进入发现书籍列表（对标 ExploreShowActivity）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/explore/explore_notifier.dart';
import '../routes.dart';
import '../screens/explore_show_screen.dart';
import '../utils/responsive.dart';
import '../widgets/empty_state.dart';
import '../widgets/explore_book_list.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

class ExploreScreen extends ConsumerStatefulWidget {
  /// 收起已展开分类信号（主页双击底栏发现项时自增，对标原版 compressExplore）
  final ValueNotifier<int>? collapseSignal;

  const ExploreScreen({super.key, this.collapseSignal});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  final _searchController = TextEditingController();

  /// 搜索防抖计时器（300ms，对标 Android SearchView onQueryTextChange）
  Timer? _debounceTimer;

  /// 平板双栏：右栏当前选中的发现分类（null 时右栏显示占位提示）
  ExploreShowArgs? _selectedCategory;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// 搜索输入防抖处理（300ms）
  void _onSearchChanged(String keyword) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        ref.read(exploreNotifierProvider.notifier).setSearchKeyword(keyword);
        setState(() {}); // 刷新搜索框清除按钮显示
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(exploreNotifierProvider);
    final colorScheme = Theme.of(context).colorScheme;

    // 响应式：expanded/large（≥840dp，对齐 UI_RESTRUCTURE_PLAN.md §6.2）启用左源右内容双栏
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth >= Responsive.mediumMax;
        return Scaffold(
      appBar: AppBar(
        // 对标原版 view_search.xml：TitleBar 内嵌胶囊搜索框，
        // 与右侧分组菜单图标同行，无标题文字
        title: SizedBox(
          height: 36,
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              // 安卓原版：搜索框提示「筛选发现源」
              hintText: '筛选发现源',
              // 安卓端 bg_searchview: 35dp圆角胶囊形、半透明填充、0.5dp描边
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        ref
                            .read(exploreNotifierProvider.notifier)
                            .clearSearch();
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(35),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(35),
                borderSide: BorderSide(
                  color: colorScheme.surfaceContainerHighest,
                  width: 0.5,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(35),
                borderSide: BorderSide(
                  color: colorScheme.primary.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        actions: [
          // 安卓原版 main_explore.xml：顶栏右侧仅一个分组按钮（ic_groups）
          PopupMenuButton<String>(
            tooltip: '分组',
            icon: const Icon(Icons.groups),
            onSelected: (group) {
              ref.read(exploreNotifierProvider.notifier).selectGroup(group);
              // 分组切换后书源列表变化，清空右栏选择
              setState(() => _selectedCategory = null);
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem<String>(
                value: '',
                checked: state.selectedGroup.isEmpty,
                child: const Text('全部'),
              ),
              for (final group in state.groups)
                CheckedPopupMenuItem<String>(
                  value: group,
                  checked: state.selectedGroup == group,
                  child: Text(group),
                ),
            ],
          ),
        ],
      ),
      body: _buildBody(state, isTablet),
    );
      },
    );
  }

  Widget _buildBody(ExploreState state, bool isTablet) {
    if (state.isLoading) {
      return const LoadingIndicator();
    }

    if (state.error != null) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(exploreNotifierProvider.notifier).refresh(),
      );
    }

    final bookSources = state.filteredBookSources;
    if (bookSources.isEmpty) {
      // 安卓原版：纯灰字居中「当前没有发现源！」
      return const EmptyState(
        icon: Icons.library_books_outlined,
        title: '当前没有发现源！',
        simple: true,
      );
    }

    if (isTablet) {
      return _buildTabletBody(state);
    }

    // 手机：安卓原版单栏列表（分组筛选仅顶栏弹出菜单，无 body 内 FilterChip 行）
    return _buildSourceList(state, isTablet: false);
  }

  /// 平板双栏布局（对齐 UI_RESTRUCTURE_PLAN.md §6.2：左侧书源列表 + 右侧内容）
  ///
  /// 手机端分类点击导航至全屏 [ExploreShowScreen]（保持安卓原版行为）；
  /// 平板端在右栏原地展示分类书籍，避免频繁跳转。
  Widget _buildTabletBody(ExploreState state) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左栏：书源列表
        Flexible(
          flex: 2,
          child: _buildSourceList(state, isTablet: true),
        ),
        VerticalDivider(width: 1, color: colorScheme.outlineVariant),
        // 右栏：选中分类的书籍内容
        Flexible(
          flex: 3,
          child: _selectedCategory == null
              ? const EmptyState(
                  icon: Icons.explore_outlined,
                  title: '选择发现分类',
                  subtitle: '展开左侧书源并点击分类，在此浏览书籍',
                  simple: true,
                )
              : ExploreBookList(
                  key: ValueKey(_selectedCategory),
                  args: _selectedCategory!,
                ),
        ),
      ],
    );
  }

  Widget _buildSourceList(ExploreState state, {required bool isTablet}) {
    // 响应式处理：安卓原版 ExploreFragment 使用 LinearLayoutManager（竖向列表）
    // 保持列表布局确保安卓保真，平板宽屏时增加水平内边距提升可读性
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = isTablet ? 16.0 : 8.0;
        final sources = state.filteredBookSources;
        return ListView.builder(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 4),
          itemCount: sources.length,
          itemBuilder: (context, index) {
            final source = sources[index];
            return _SourceItem(
              source: source,
              isTablet: isTablet,
              collapseSignal: widget.collapseSignal,
              // 对标 Android editSource(sourceUrl) → BookSourceEditActivity
              onEdit: () {
                Navigator.pushNamed(
                  context,
                  AppRoutes.sourceEdit,
                  arguments: source,
                );
              },
              onUninstall: () => _onUninstall(source.bookSourceUrl),
              // 对标 Android openExplore(sourceUrl, title, exploreUrl) → ExploreShowActivity
              onCategoryTap: (categoryName, categoryUrl) {
                _openExploreShow(source, categoryName, categoryUrl, isTablet);
              },
            );
          },
        );
      },
    );
  }

  /// 打开发现分类书籍列表（对标 Android openExplore → ExploreShowActivity）
  ///
  /// 手机：导航至全屏 [ExploreShowScreen]（保持安卓原版行为）；
  /// 平板：在右栏原地展示分类书籍。
  void _openExploreShow(
    BookSource source,
    String categoryName,
    String categoryUrl,
    bool isTablet,
  ) {
    final args = ExploreShowArgs(
      source: source,
      categoryName: categoryName,
      categoryUrl: categoryUrl,
    );
    if (isTablet) {
      setState(() => _selectedCategory = args);
      return;
    }
    Navigator.pushNamed(context, AppRoutes.exploreShow, arguments: args);
  }

  Future<void> _onUninstall(String sourceUrl) async {
    final ok =
        await ref.read(exploreNotifierProvider.notifier).uninstallSource(sourceUrl);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已卸载'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }
}

/// 书源列表项（参考安卓端 item_find_book.xml 分组标题行样式）
class _SourceItem extends ConsumerStatefulWidget {
  final BookSource source;
  final VoidCallback onEdit;
  final VoidCallback onUninstall;

  /// 是否处于平板双栏模式（分类点击在右栏展示而非导航）
  final bool isTablet;

  /// 收起展开信号（主页双击底栏发现项时自增，对标原版 compressExplore）
  final ValueNotifier<int>? collapseSignal;

  /// 分类点击回调（对标 Android ExploreAdapter.CallBack.openExplore）
  final void Function(String categoryName, String categoryUrl)? onCategoryTap;

  const _SourceItem({
    required this.source,
    required this.onEdit,
    required this.onUninstall,
    required this.isTablet,
    this.collapseSignal,
    this.onCategoryTap,
  });

  @override
  ConsumerState<_SourceItem> createState() => _SourceItemState();
}

class _SourceItemState extends ConsumerState<_SourceItem> {
  /// 是否展开分类列表
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    widget.collapseSignal?.addListener(_onCollapseSignal);
  }

  @override
  void dispose() {
    widget.collapseSignal?.removeListener(_onCollapseSignal);
    super.dispose();
  }

  /// 双击底栏发现项 → 收起已展开的分类列表
  void _onCollapseSignal() {
    if (_expanded) {
      setState(() => _expanded = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bookName = widget.source.bookSourceName;

    // 安卓端 item_find_book.xml：ll_title 带 bg_find_book_group，
    // 仅 tv_name + iv_status，无评论/URL 副行
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Material(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: () => _toggleExpand(),
              onLongPress: _showItemMenu,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        bookName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.arrow_drop_down
                          : Icons.arrow_forward_ios,
                      size: _expanded ? 24 : 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded) _buildCategoryList(theme, colorScheme),
      ],
    );
  }

  /// 长按弹出项菜单（对标原版列表项长按菜单：编辑/删除）
  Future<void> _showItemMenu() async {
    // 以项自身左上角为锚点弹出菜单
    final box = context.findRenderObject() as RenderBox?;
    final pos = box != null ? box.localToGlobal(Offset.zero) : Offset.zero;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        PopupMenuItem(
          value: 'uninstall',
          child: Text(
            '删除',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        widget.onEdit();
      case 'uninstall':
        widget.onUninstall();
    }
  }

  /// 切换展开/收起分类列表
  void _toggleExpand() {
    setState(() {
      _expanded = !_expanded;
    });
    // 展开时加载分类（Notifier 内部已做缓存/去重，幂等）
    if (_expanded) {
      ref.read(exploreNotifierProvider.notifier).loadCategories(widget.source);
    }
  }

  /// 构建分类标签列表（对标 Android ExploreAdapter 中的分类 FlowLayout）
  Widget _buildCategoryList(ThemeData theme, ColorScheme colorScheme) {
    final sourceUrl = widget.source.bookSourceUrl;
    // 通过 select 精准订阅该书源的分类加载状态，避免无关重建
    final loading = ref.watch(exploreNotifierProvider.select(
      (s) => s.isLoadingCategories(sourceUrl),
    ));
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: SizedBox(
          height: 24,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }

    final categories = ref.watch(exploreNotifierProvider.select(
          (s) => s.categoriesFor(sourceUrl),
        )) ??
        [];
    if (categories.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          '无分类',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // 分类标签流式布局（对标 Android flexbox 布局）
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: widget.isTablet ? 16 : 10,
        vertical: 8,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: categories.map((category) {
          final hasUrl = category.url != null && category.url!.isNotEmpty;
          // 分组标题行（url 为空，对标 ExploreKind 仅 title）
          if (!hasUrl) {
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                category.title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }
          return ActionChip(
            label: Text(category.title),
            onPressed: hasUrl
                ? () => widget.onCategoryTap?.call(
                      category.title,
                      category.url!,
                    )
                : null,
          );
        }).toList(),
      ),
    );
  }
}
