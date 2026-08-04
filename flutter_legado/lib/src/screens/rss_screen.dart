import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/rss/rss_notifier.dart';
import '../routes.dart';
import '../utils/responsive.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_articles_screen.dart';

/// RSS 源列表页面
class RssScreen extends ConsumerStatefulWidget {
  const RssScreen({super.key});

  @override
  ConsumerState<RssScreen> createState() => _RssScreenState();
}

class _RssScreenState extends ConsumerState<RssScreen> {
  /// 顶栏搜索框（对齐安卓原版 fragment_rss.xml 的 view_search：
  /// 实时按名称/URL 过滤已启用订阅源）
  final _searchController = TextEditingController();
  String _searchKey = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssNotifierProvider.notifier).loadSources();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 在分组过滤基础上叠加搜索过滤（对标原版 flowEnabled(searchKey)）
  List<RssSource> _applySearch(List<RssSource> sources) {
    final key = _searchKey.trim().toLowerCase();
    if (key.isEmpty) return sources;
    return sources
        .where((s) =>
            s.sourceName.toLowerCase().contains(key) ||
            s.sourceUrl.toLowerCase().contains(key))
        .toList();
  }

  void _confirmDeleteSource(RssSource source) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除 RSS 源'),
        content: Text('确定要删除「${source.sourceName}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              ref.read(rssNotifierProvider.notifier).removeSource(source.sourceUrl);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssNotifierProvider);
    final notifier = ref.read(rssNotifierProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        // 对标原版 view_search.xml：TitleBar 内嵌胶囊搜索框（hint「订阅」），
        // 与右侧 4 个图标入口同行，无标题文字
        title: SizedBox(
          height: 36,
          child: TextField(
            controller: _searchController,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            decoration: InputDecoration(
              // 安卓原版 queryHint = 订阅
              hintText: AppStrings.rss,
              hintStyle: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              prefixIcon: Icon(Icons.search,
                  size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
              suffixIcon: _searchKey.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear,
                          size: 18,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchKey = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(35),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (value) => setState(() => _searchKey = value),
          ),
        ),
        actions: [
          // 安卓原版顶栏 4 个功能入口：历史/收藏/分组/设置
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.rssHistory),
          ),
          IconButton(
            icon: const Icon(Icons.star_outline),
            tooltip: '收藏',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.rssFavorites),
          ),
          // 分组筛选：对齐原版 RssFragment 的分组菜单（ic_groups 图标，linkedSetOf 保序聚合）
          PopupMenuButton<String?>(
            tooltip: '分组',
            icon: const Icon(Icons.groups),
            onSelected: (group) => notifier.setGroup(group),
            itemBuilder: (context) => [
              const PopupMenuItem<String?>(
                value: null,
                child: Text('全部'),
              ),
              for (final group in state.groups)
                PopupMenuItem<String?>(
                  value: group,
                  child: Text(group),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.rssConfig),
          ),
        ],
      ),
      // 安卓原版无 FAB：添加订阅源入口在订阅源管理页（对标 RssSourceActivity 菜单）
      body: Builder(
        builder: (context) {
          if (state.isLoadingSources && state.sources.isEmpty) {
            return const LoadingIndicator(message: '加载 RSS 源...');
          }

          if (state.error != null && state.sources.isEmpty) {
            return ErrorView(
              message: state.error!,
              onRetry: () => notifier.loadSources(),
            );
          }

          if (state.isEmpty) {
            // 安卓原版：纯灰字居中空状态
            return const EmptyState(
              icon: Icons.rss_feed,
              title: '当前没有订阅源！',
              simple: true,
            );
          }

          // 分组/搜索过滤后为空：提示当前无订阅源
          final displaySources = _applySearch(state.filteredSources);
          if (displaySources.isEmpty) {
            return const EmptyState(
              icon: Icons.rss_feed,
              title: '当前分组暂无订阅源',
              simple: true,
            );
          }

          return RefreshIndicator(
            onRefresh: () => notifier.loadSources(),
            // 安卓端使用 GridLayoutManager spanCount=4
            // 手机 4 列对齐原版，宽屏上限 6 列
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    Responsive.rssGridColumnsForWidth(constraints.maxWidth);
                final aspectRatio =
                    Responsive.rssGridChildAspectRatio(constraints.maxWidth);
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    childAspectRatio: aspectRatio,
                    // iOS 风格：加大网格间距，配合图标阴影留出呼吸感
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: displaySources.length,
                  itemBuilder: (context, index) {
                    final source = displaySources[index];
                    return _buildSourceItem(context, source);
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 安卓端 item_rss.xml 样式：居中图标(50x50 圆角12dp) + 名称(13sp 居中 最多2行)
  Widget _buildSourceItem(BuildContext context, RssSource source) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 稳定 ValueKey（sourceUrl）+ RepaintBoundary 隔离网格项重绘区域
    final item = InkWell(
      key: ValueKey(source.sourceUrl),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RssArticlesScreen(source: source),
          ),
        );
      },
      onLongPress: () => _confirmDeleteSource(source),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        // 安卓端 item 内边距 16dp；窄屏缩至 12dp 防溢出
        padding: EdgeInsets.all(
          Responsive.isCompact(MediaQuery.sizeOf(context).width) ? 12 : 16,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 图标：50x50 圆角12dp（安卓端 FilletImageView radius=12dp）
            // iOS 风格：圆角图标 + 柔和阴影，类似主屏 App 图标
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: source.sourceIcon.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: source.sourceIcon,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        // 限制解码宽度为图标实际显示像素宽度（50），避免大图解码
                        memCacheWidth: (50 *
                                (MediaQuery.maybeOf(context)?.devicePixelRatio ??
                                    1.0))
                            .round(),
                        placeholder: (_, _) => _buildPlaceholderIcon(
                            context, source, colorScheme),
                        errorWidget: (_, _, _) => _buildPlaceholderIcon(
                            context, source, colorScheme),
                      )
                    : _buildPlaceholderIcon(context, source, colorScheme),
              ),
            ),
            // 名称：安卓端 marginTop=16dp, 13sp, secondaryText, 居中, 最多2行
            const SizedBox(height: 16),
            Text(
              source.sourceName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
    return RepaintBoundary(child: item);
  }

  /// 占位图标：显示源名称首字母（iOS 风格柔和填充底）
  Widget _buildPlaceholderIcon(
      BuildContext context, RssSource source, ColorScheme colorScheme) {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Text(
          source.sourceName.isNotEmpty
              ? source.sourceName[0].toUpperCase()
              : 'R',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
