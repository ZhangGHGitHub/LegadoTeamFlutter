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
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/explore_provider.dart';
import '../routes.dart';
import '../screens/explore_show_screen.dart';
import '../services/book_api.dart';
import '../utils/responsive.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final _searchController = TextEditingController();

  /// 搜索防抖计时器（300ms，对标 Android SearchView onQueryTextChange）
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ExploreProvider>().loadBookSources();
    });
  }

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
        context.read<ExploreProvider>().setSearchKeyword(keyword);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ExploreProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.discover),
        actions: [
          // 安卓原版：右侧为筛选（田形网格）图标
          IconButton(
            icon: const Icon(Icons.grid_view),
            tooltip: '筛选',
            onPressed: () => provider.refreshBookSources(),
          ),
        ],
        // 安卓端 fragment_explore.xml: TitleBar 内嵌 view_search 搜索框
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SizedBox(
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
                            provider.clearSearch();
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
          ),
        ),
      ),
      body: _buildBody(provider),
    );
  }

  Widget _buildBody(ExploreProvider provider) {
    if (provider.loading) {
      return const LoadingIndicator();
    }

    if (provider.error != null) {
      return ErrorView(
        message: provider.error!,
        onRetry: () => provider.loadBookSources(),
      );
    }

    final bookSources = provider.filteredBookSources;
    if (bookSources.isEmpty) {
      // 安卓原版：纯灰字居中「当前没有发现源！」
      return const EmptyState(
        icon: Icons.library_books_outlined,
        title: '当前没有发现源！',
        simple: true,
      );
    }

    return Column(
      children: [
        // 分组选择器
        SizedBox(
          height: 56,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: provider.groups.length + 1, // +1 为"全部"选项
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: FilterChip(
                    label: const Text('全部'),
                    selected: provider.selectedGroup.isEmpty,
                    onSelected: (_) {
                      provider.selectGroup('');
                    },
                  ),
                );
              } else {
                final group = provider.groups.elementAt(index - 1);
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: FilterChip(
                    label: Text(group),
                    selected: provider.selectedGroup == group,
                    onSelected: (_) {
                      provider.selectGroup(group);
                    },
                  ),
                );
              }
            },
          ),
        ),
        Expanded(child: _buildSourceList(provider)),
      ],
    );
  }

  Widget _buildSourceList(ExploreProvider provider) {
    // 响应式处理：安卓原版 ExploreFragment 使用 LinearLayoutManager（竖向列表）
    // 保持列表布局确保安卓保真，平板宽屏时增加水平内边距提升可读性
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth >= Responsive.compactMax;
        final horizontalPadding = isTablet ? 24.0 : 8.0;
        return ListView.builder(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 4),
          itemCount: provider.filteredBookSources.length,
          itemBuilder: (context, index) {
            final source = provider.filteredBookSources[index];
            return _SourceItem(
              source: source,
              // 对标 Android editSource(sourceUrl) → BookSourceEditActivity
              onEdit: () {
                Navigator.pushNamed(
                  context,
                  AppRoutes.sourceEdit,
                  arguments: source,
                );
              },
              onUninstall: () => _onUninstall(provider, source.bookSourceUrl),
              // 对标 Android openExplore(sourceUrl, title, exploreUrl) → ExploreShowActivity
              onCategoryTap: (categoryName, categoryUrl) {
                _openExploreShow(source, categoryName, categoryUrl);
              },
            );
          },
        );
      },
    );
  }

  /// 打开发现分类书籍列表（对标 Android openExplore → ExploreShowActivity）
  void _openExploreShow(BookSource source, String categoryName, String categoryUrl) {
    Navigator.pushNamed(
      context,
      AppRoutes.exploreShow,
      arguments: ExploreShowArgs(
        source: source,
        categoryName: categoryName,
        categoryUrl: categoryUrl,
      ),
    );
  }

  Future<void> _onUninstall(ExploreProvider provider, String sourceUrl) async {
    final ok = await provider.uninstallSource(sourceUrl);
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
class _SourceItem extends StatefulWidget {
  final BookSource source;
  final VoidCallback onEdit;
  final VoidCallback onUninstall;

  /// 分类点击回调（对标 Android ExploreAdapter.CallBack.openExplore）
  final void Function(String categoryName, String categoryUrl)? onCategoryTap;

  const _SourceItem({
    required this.source,
    required this.onEdit,
    required this.onUninstall,
    this.onCategoryTap,
  });

  @override
  State<_SourceItem> createState() => _SourceItemState();
}

class _SourceItemState extends State<_SourceItem> {
  /// 是否展开分类列表
  bool _expanded = false;

  /// 解析后的分类列表
  List<ExploreCategory>? _categories;

  /// 是否正在加载分类
  bool _loadingCategories = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final source = widget.source;

    // 提取书源信息
    final bookName = source.bookSourceName;
    final bookSourceComment = source.bookSourceComment ?? '';
    final url = source.bookSourceUrl;

    // 安卓端 item_find_book.xml: 分组标题行样式
    // paddingLeft/Right=10dp, paddingTop/Bottom=6dp, 名称左侧 + 箭头图标右侧
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _toggleExpand(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 书源名称（安卓端 tv_name: primaryText 色）
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
                    // 编辑按钮
                    InkWell(
                      onTap: widget.onEdit,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.edit_outlined,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    // 删除按钮
                    InkWell(
                      onTap: widget.onUninstall,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    // 安卓端 iv_status: 箭头图标 20x20 secondaryText色
                    Icon(
                      _expanded
                          ? Icons.arrow_drop_down
                          : Icons.arrow_forward_ios,
                      size: _expanded ? 24 : 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                // 摘要信息
                if (bookSourceComment.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      bookSourceComment,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // URL 信息
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    url,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 分类列表（展开时显示，对标 Android ExploreAdapter 分类标签）
        if (_expanded) _buildCategoryList(theme, colorScheme),
      ],
    );
  }

  /// 切换展开/收起分类列表
  void _toggleExpand() {
    setState(() {
      _expanded = !_expanded;
    });
    // 首次展开时加载分类
    if (_expanded && _categories == null) {
      _loadCategories();
    }
  }

  /// 加载分类列表（通过 Rust FFI 解析 exploreUrl）
  Future<void> _loadCategories() async {
    final exploreUrl = widget.source.exploreUrl;
    if (exploreUrl == null || exploreUrl.trim().isEmpty) {
      setState(() {
        _categories = [];
      });
      return;
    }

    setState(() {
      _loadingCategories = true;
    });

    try {
      final api = context.read<BookApi>();
      final categories = await api.exploreParseUrl(exploreUrl);
      if (mounted) {
        setState(() {
          _categories = categories;
          _loadingCategories = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _categories = [];
          _loadingCategories = false;
        });
      }
    }
  }

  /// 构建分类标签列表（对标 Android ExploreAdapter 中的分类 FlowLayout）
  Widget _buildCategoryList(ThemeData theme, ColorScheme colorScheme) {
    if (_loadingCategories) {
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

    final categories = _categories ?? [];
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: categories.map((category) {
          final hasUrl = category.url != null && category.url!.isNotEmpty;
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
