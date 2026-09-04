/// 书源探索页面（ExploreScreen）
///
/// 参考 Android 原版 ExploreFragment.kt 实现
/// 核心功能：
/// 1. 显示已安装的书源列表
/// 2. 支持实时搜索过滤（300ms 防抖）
/// 3. 按分组筛选书源
/// 4. 一键安装/卸载书源（CRUD 操作）
/// 5. 点击分类进入发现书籍列表（对标 ExploreShowActivity）
///
/// 视觉：iOS inset grouped list + 顶栏嵌入式搜索 — Composer + UI
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/explore/explore_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../screens/explore_show_screen.dart';
import '../utils/responsive.dart';
import '../utils/source_login_entry.dart';
import '../widgets/empty_state.dart';
import '../widgets/explore_book_list.dart';
import '../widgets/explore_kind_layout.dart';
import '../widgets/explore_page_control.dart';
import '../widgets/error_view.dart';
import '../widgets/ios_widgets.dart';
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

  static const _kExpandDuration = Duration(milliseconds: 250);

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
          appBar: LegadoAppBar(
            titleSpacing: 8,
            // iOS 顶栏嵌入式搜索：克制圆角、系统灰底
            title: SizedBox(
              height: 36,
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: colorScheme.onSurface),
                decoration: InputDecoration(
                  hintText: '筛选发现源',
                  hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                  filled: true,
                  fillColor:
                      colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  prefixIcon: Icon(
                    Symbols.search_rounded,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(
                            Symbols.close_rounded,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          onPressed: () {
                            _searchController.clear();
                            ref
                                .read(exploreNotifierProvider.notifier)
                                .clearSearch();
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: colorScheme.primary.withValues(alpha: 0.45),
                      width: 1,
                    ),
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: '分组',
                icon: const Icon(Symbols.groups_rounded),
                onSelected: (group) {
                  ref.read(exploreNotifierProvider.notifier).selectGroup(group);
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
      return const EmptyState(
        icon: Symbols.library_books_rounded,
        title: '当前没有发现源！',
        simple: true,
      );
    }

    if (isTablet) {
      return _buildTabletBody(state);
    }

    return _buildSourceList(state, isTablet: false);
  }

  /// 平板双栏布局（对齐 UI_RESTRUCTURE_PLAN.md §6.2：左侧书源列表 + 右侧内容）
  Widget _buildTabletBody(ExploreState state) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          flex: 2,
          child: _buildSourceList(state, isTablet: true),
        ),
        VerticalDivider(width: 1, color: colorScheme.outlineVariant),
        Flexible(
          flex: 3,
          child: _selectedCategory == null
              ? const EmptyState(
                  icon: Symbols.explore_rounded,
                  title: '选择发现分类',
                  subtitle: '展开左侧书源并点击分类，在此浏览书籍',
                  simple: true,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 10, 4, 6),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: colorScheme.outlineVariant
                                .withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _selectedCategory!.categoryName,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ExplorePageControl(args: _selectedCategory!),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ExploreBookList(
                        key: ValueKey(_selectedCategory),
                        args: _selectedCategory!,
                        padding: const EdgeInsets.only(bottom: 8),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSourceList(ExploreState state, {required bool isTablet}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = isTablet ? 12.0 : 16.0;
        final sources = state.filteredBookSources;
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            8,
            horizontalPadding,
            16,
          ),
          itemCount: sources.length,
          itemBuilder: (context, index) {
            final source = sources[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SourceItem(
                source: source,
                isTablet: isTablet,
                collapseSignal: widget.collapseSignal,
                expandDuration: _kExpandDuration,
                onEdit: () {
                  Navigator.pushNamed(
                    context,
                    AppRoutes.sourceEdit,
                    arguments: source,
                  );
                },
                onUninstall: () => _onUninstall(source.bookSourceUrl),
                onTop: () => _onTopSource(source),
                onLogin: () => _onLoginSource(source),
                onSearch: () => _onSearchSource(source),
                onRefresh: () =>
                    ref.read(exploreNotifierProvider.notifier).reloadCategories(source),
                onCategoryTap: (categoryName, categoryUrl) {
                  _openExploreShow(source, categoryName, categoryUrl, isTablet);
                },
              ),
            );
          },
        );
      },
    );
  }

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

  /// 书源置顶（对齐原版 ExploreViewModel.topSource：
  /// customOrder = 当前最小 order - 1，置顶到最前）— 发现页修复 R2
  Future<void> _onTopSource(BookSource source) async {
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      var minOrder = 0;
      for (final s in sources) {
        if (s.customOrder < minOrder) minOrder = s.customOrder;
      }
      final updated = source.copyWith(customOrder: minOrder - 1);
      await api.updateBookSource(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已置顶'),
          duration: Duration(seconds: 1),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('置顶失败: $e')),
      );
    }
  }

  /// 书源登录（统一入口：V2 动态对话框 / 手动凭据页）— 发现页修复 R2
  Future<void> _onLoginSource(BookSource source) async {
    final ok = await showSourceLogin(context, ref, source);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('登录成功'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// 按指定书源搜索（对齐原版 ExploreAdapter "search" → SearchActivity.start）— R2
  void _onSearchSource(BookSource source) {
    Navigator.pushNamed(
      context,
      AppRoutes.search,
      arguments: {'sourceUrl': source.bookSourceUrl},
    );
  }
}

/// 书源列表项：iOS 分组卡片标题行 + 展开分类 inset list
class _SourceItem extends ConsumerStatefulWidget {
  final BookSource source;
  final VoidCallback onEdit;
  final VoidCallback onUninstall;
  final VoidCallback onTop;
  final VoidCallback onLogin;
  final VoidCallback onSearch;
  final VoidCallback onRefresh;
  final bool isTablet;
  final ValueNotifier<int>? collapseSignal;
  final Duration expandDuration;
  final void Function(String categoryName, String categoryUrl)? onCategoryTap;

  const _SourceItem({
    required this.source,
    required this.onEdit,
    required this.onUninstall,
    required this.onTop,
    required this.onLogin,
    required this.onSearch,
    required this.onRefresh,
    required this.isTablet,
    required this.expandDuration,
    this.collapseSignal,
    this.onCategoryTap,
  });

  @override
  ConsumerState<_SourceItem> createState() => _SourceItemState();
}

class _SourceItemState extends ConsumerState<_SourceItem>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _expandController;
  late final Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      vsync: this,
      duration: widget.expandDuration,
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeInOut,
    );
    widget.collapseSignal?.addListener(_onCollapseSignal);
  }

  @override
  void dispose() {
    widget.collapseSignal?.removeListener(_onCollapseSignal);
    _expandController.dispose();
    super.dispose();
  }

  void _onCollapseSignal() {
    if (_expanded) {
      _setExpanded(false);
    }
  }

  void _setExpanded(bool value) {
    setState(() => _expanded = value);
    if (value) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bookName = widget.source.bookSourceName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosGroup(flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _toggleExpand,
                onLongPress: _showItemMenu,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            bookName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        AnimatedRotation(
                          turns: _expanded ? 0.25 : 0,
                          duration: widget.expandDuration,
                          curve: Curves.easeInOut,
                          child: Icon(
                            Symbols.chevron_right_rounded,
                            size: 20,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        SizeTransition(
          sizeFactor: _expandAnimation,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: _expandAnimation,
            child: _buildCategoryList(theme, colorScheme),
          ),
        ),
      ],
    );
  }

  Future<void> _showItemMenu() async {
    final box = context.findRenderObject() as RenderBox?;
    final pos = box != null ? box.localToGlobal(Offset.zero) : Offset.zero;
    // 书源行菜单（对齐原版 ExploreAdapter.showMenu 六项：
    // 编辑/置顶/登录(hasLoginUrl 条件)/搜索/刷新/删除）— 发现页修复 R2
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        const PopupMenuItem(value: 'top', child: Text('置顶')),
        if (_hasLoginUrl)
          const PopupMenuItem(value: 'login', child: Text('登录')),
        const PopupMenuItem(value: 'search', child: Text('搜索')),
        const PopupMenuItem(value: 'refresh', child: Text('刷新')),
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
      case 'top':
        widget.onTop();
      case 'login':
        widget.onLogin();
      case 'search':
        widget.onSearch();
      case 'refresh':
        widget.onRefresh();
      case 'uninstall':
        widget.onUninstall();
    }
  }

  /// 是否有登录入口（对齐原版 BookSourcePart.hasLoginUrl SQL 计算列：
  /// loginUrl 非空，或 mainJs + loginUi 非空且非 `[]`）— R2
  bool get _hasLoginUrl {
    final s = widget.source;
    final loginUrl = (s.loginUrl ?? '').trim();
    if (loginUrl.isNotEmpty) return true;
    final mainJs = (s.mainJs ?? '').trim();
    final loginUi = (s.loginUi ?? '').replaceAll(RegExp(r'\s'), '');
    return mainJs.isNotEmpty && loginUi.isNotEmpty && loginUi != '[]';
  }

  void _toggleExpand() {
    final next = !_expanded;
    _setExpanded(next);
    if (next) {
      ref.read(exploreNotifierProvider.notifier).loadCategories(widget.source);
    }
  }

  Widget _buildCategoryList(ThemeData theme, ColorScheme colorScheme) {
    final sourceUrl = widget.source.bookSourceUrl;
    final loading = ref.watch(exploreNotifierProvider.select(
      (s) => s.isLoadingCategories(sourceUrl),
    ));
    if (loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 4),
        child: SizedBox(
          height: 44,
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
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
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
        child: Text(
          '无分类',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExploreKindLayout(
        sourceUrl: sourceUrl,
        sourceJson: jsonEncode(widget.source.toJson()),
        categories: categories,
        onCategoryTap: widget.onCategoryTap,
        onRefreshCategories: () => ref
            .read(exploreNotifierProvider.notifier)
            .reloadCategories(widget.source),
      ),
    );
  }
}
