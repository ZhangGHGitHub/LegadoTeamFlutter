/// 发现页「源内容模式」页面（参考版 ExploreMainRoute 的 showContent 分支）
///
/// 参考版依据：
/// - `feature/explore/ExploreMainRoute.kt:129-195`：顶栏 = 标题+书源名，
///   动作 = 单书源搜索 / 切回源列表 / 书源选择，bottomContent = 分类 Tab；
/// - `feature/explore/ExploreMainViewModel.kt`：分类恢复与书源选择；
/// - `ui/book/explore/ExploreShowScreen.kt`：分类内容列表与页码动作。
///
/// 本实现复用 [ExploreBookList]（发现书单卡片/分页/下拉刷新）与
/// [ExplorePageControl]（页码跳转），分类数据复用 [ExploreNotifier]
/// 的 `exploreParseUrl` 缓存（与源列表展开区同源，不重复解析）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../models/models.dart';
import '../providers/explore/explore_main_notifier.dart';
import '../providers/explore/explore_main_state.dart';
import '../providers/explore/explore_notifier.dart';
import '../providers/explore/explore_show_notifier.dart';
import '../routes.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/explore_book_list.dart';
import '../widgets/explore_kind_select_sheet.dart';
import '../widgets/explore_page_control.dart';
import '../widgets/explore_source_select_sheet.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/skeleton.dart';

class ExploreSourceContent extends ConsumerStatefulWidget {
  /// 当前源内容模式书源（由发现页按持久化选择解析后传入）
  final BookSource source;

  const ExploreSourceContent({super.key, required this.source});

  @override
  ConsumerState<ExploreSourceContent> createState() =>
      _ExploreSourceContentState();
}

class _ExploreSourceContentState extends ConsumerState<ExploreSourceContent> {
  @override
  void initState() {
    super.initState();
    _ensureCategories();
  }

  @override
  void didUpdateWidget(covariant ExploreSourceContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.bookSourceUrl != widget.source.bookSourceUrl) {
      _ensureCategories();
    }
  }

  /// 触发分类解析（ExploreNotifier 内部幂等，已缓存/加载中直接返回）
  void _ensureCategories() {
    Future.microtask(() {
      if (!mounted) return;
      ref.read(exploreNotifierProvider.notifier).loadCategories(widget.source);
    });
  }

  Future<void> _retryCategories() async {
    await ref
        .read(exploreNotifierProvider.notifier)
        .reloadCategories(widget.source);
  }

  @override
  Widget build(BuildContext context) {
    final sourceUrl = widget.source.bookSourceUrl;
    final categories = ref.watch(
      exploreNotifierProvider.select((s) => s.categoriesFor(sourceUrl)),
    );
    final loadingCategories = ref.watch(
      exploreNotifierProvider.select((s) => s.isLoadingCategories(sourceUrl)),
    );
    final main = ref.watch(exploreMainNotifierProvider);
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    final kinds = loadableExploreMainKinds(categories ?? const []);
    final savedKey = main.kindKeyFor(sourceUrl);
    final selectedKind =
        kinds.where((k) => exploreKindKey(k) == savedKey).firstOrNull ??
        kinds.firstOrNull;
    final selectedArgs = _buildShowArgs(selectedKind);

    return AppScaffold(
      topBar: LegadoAppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('发现'),
            Text(
              widget.source.bookSourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          // 单书源搜索（等价参考版长按书源的「搜索」：带 sourceUrl 进搜索页）
          IconButton(
            tooltip: '搜索该书源',
            icon: const Icon(Symbols.search_rounded),
            onPressed: () => Navigator.pushNamed(
              context,
              AppRoutes.search,
              arguments: {'sourceUrl': sourceUrl},
            ),
          ),
          // 切回源列表
          IconButton(
            tooltip: '返回源列表',
            icon: const Icon(Symbols.swap_horiz_rounded),
            onPressed: () => ref
                .read(exploreMainNotifierProvider.notifier)
                .setShowContent(false),
          ),
          // 书源选择 sheet（搜索/分组/布局列数）
          IconButton(
            tooltip: '选择书源',
            icon: const Icon(Symbols.more_vert_rounded),
            onPressed: () => showExploreSourceSelectSheet(context),
          ),
        ],
        // 分类 Tab + 页码按钮 + 分类选择
        bottom: kinds.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      Expanded(
                        child: _KindTabStrip(
                          kinds: kinds,
                          selectedKey: selectedKind == null
                              ? ''
                              : exploreKindKey(selectedKind),
                          onSelected: (kind) => ref
                              .read(exploreMainNotifierProvider.notifier)
                              .selectKind(sourceUrl, exploreKindKey(kind)),
                        ),
                      ),
                      if (selectedArgs != null) ...[
                        // [批39 审查回修] 源内容模式同样提供刷新入口
                        // （page>1 时下拉刷新被「加载上一页」占用）
                        ExploreRefreshControl(args: selectedArgs),
                        ExplorePageControl(args: selectedArgs),
                      ],
                      IconButton(
                        tooltip: '选择分类',
                        icon: const Icon(
                          Symbols.format_list_bulleted_rounded,
                          size: 20,
                        ),
                        onPressed: () => _showKindSheet(kinds, selectedKind),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      body: _buildBody(
        categories: categories,
        loadingCategories: loadingCategories,
        kinds: kinds,
        selectedArgs: selectedArgs,
        gridColumns: main.gridMode
            ? main.gridCountFor(landscape: landscape)
            : null,
      ),
    );
  }

  ExploreShowArgs? _buildShowArgs(ExploreCategory? kind) {
    final url = kind?.url?.trim() ?? '';
    if (kind == null || url.isEmpty) return null;
    return ExploreShowArgs(
      source: widget.source,
      categoryName: kind.title,
      categoryUrl: url,
    );
  }

  Widget _buildBody({
    required List<ExploreCategory>? categories,
    required bool loadingCategories,
    required List<ExploreCategory> kinds,
    required ExploreShowArgs? selectedArgs,
    required int? gridColumns,
  }) {
    // 分类尚未解析完成：首屏 Skeleton（与发现源列表首屏一致）
    if (categories == null) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: 8,
        itemBuilder: (_, _) => const ListSkeletonItem(),
      );
    }

    // 解析失败：缓存中只有一条 ERROR 占位（url = 错误详情）
    final errorText = _errorOnlyMessage(categories);
    if (errorText != null) {
      return ErrorView(message: errorText, onRetry: _retryCategories);
    }

    if (kinds.isEmpty) {
      if (loadingCategories) {
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          itemCount: 8,
          itemBuilder: (_, _) => const ListSkeletonItem(),
        );
      }
      return EmptyState(
        icon: Symbols.explore_rounded,
        title: '该源没有可用分类',
        subtitle: '书源发现规则未解析出可浏览的分类',
        action: TextButton(
          onPressed: _retryCategories,
          child: const Text('重新解析'),
        ),
      );
    }

    if (selectedArgs == null) {
      return const EmptyState(
        icon: Symbols.explore_rounded,
        title: '分类缺少地址',
        subtitle: '请选择其他分类或刷新书源发现规则',
      );
    }

    return ExploreBookList(
      key: ValueKey(selectedArgs),
      args: selectedArgs,
      gridCount: gridColumns,
      padding: const EdgeInsets.only(bottom: 8),
    );
  }

  void _showKindSheet(
    List<ExploreCategory> kinds,
    ExploreCategory? selectedKind,
  ) async {
    final picked = await showExploreKindSelectSheet(
      context: context,
      kinds: kinds,
      selectedKey: selectedKind == null ? '' : exploreKindKey(selectedKind),
    );
    if (picked == null || !mounted) return;
    ref
        .read(exploreMainNotifierProvider.notifier)
        .selectKind(widget.source.bookSourceUrl, exploreKindKey(picked));
  }

  /// ERROR 占位判定（ExploreNotifier.loadCategories 失败时缓存单条 ERROR）
  String? _errorOnlyMessage(List<ExploreCategory> categories) {
    if (categories.length != 1) return null;
    final title = categories.first.title;
    if (title != 'ERROR' && !title.startsWith('ERROR:')) return null;
    final detail = categories.first.url?.trim() ?? '';
    if (title.startsWith('ERROR:')) {
      return title;
    }
    return detail.isEmpty ? '分类解析失败' : detail;
  }
}

/// 分类 Tab 横滑条（选中项加下划线指示，对齐参考版 AppTabRow）
///
/// 恢复上次浏览分类时把选中项滚入可视区（对齐参考版 AppTabRow 的
/// `LaunchedEffect(selectedTabIndex)` → `animateScrollToItem`）。
class _KindTabStrip extends StatefulWidget {
  final List<ExploreCategory> kinds;
  final String selectedKey;
  final ValueChanged<ExploreCategory> onSelected;

  const _KindTabStrip({
    required this.kinds,
    required this.selectedKey,
    required this.onSelected,
  });

  @override
  State<_KindTabStrip> createState() => _KindTabStripState();
}

class _KindTabStripState extends State<_KindTabStrip> {
  final Map<String, GlobalKey> _itemKeys = {};
  String _ensuredKey = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSelectedVisible());
  }

  @override
  void didUpdateWidget(covariant _KindTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedKey != widget.selectedKey) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureSelectedVisible(),
      );
    }
  }

  /// 把当前选中分类滚到横条中部（首次恢复 / 用户切换都适用）
  void _ensureSelectedVisible() {
    if (!mounted) return;
    final key = widget.selectedKey;
    if (key.isEmpty || key == _ensuredKey) return;
    final itemContext = _itemKeys[key]?.currentContext;
    if (itemContext == null) return;
    _ensuredKey = key;
    Scrollable.ensureVisible(
      itemContext,
      alignment: 0.5,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (final kind in widget.kinds)
            Builder(
              builder: (context) {
                final key = exploreKindKey(kind);
                final selected = key == widget.selectedKey;
                return InkWell(
                  key: _itemKeys.putIfAbsent(key, GlobalKey.new),
                  onTap: () => widget.onSelected(kind),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 8),
                        Text(
                          kind.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: selected
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                        ),
                        const SizedBox(height: 6),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          height: 2,
                          width: selected ? 20 : 0,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
