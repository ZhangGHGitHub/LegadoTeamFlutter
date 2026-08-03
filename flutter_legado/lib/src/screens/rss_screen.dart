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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssNotifierProvider.notifier).loadSources();
    });
  }

  void _showAddSourceDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加 RSS 源'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：少数派',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'RSS 地址',
                  hintText: 'https://sspai.com/feed',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入 RSS 地址';
                  if (!v.startsWith('http')) return '地址必须以 http(s) 开头';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(dialogContext);
                ref.read(rssNotifierProvider.notifier).addSource(
                      nameController.text.trim(),
                      urlController.text.trim(),
                    );
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
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
        title: Text(AppStrings.rss),
        actions: [
          // 安卓原版顶栏 4 个功能入口：历史/收藏/筛选/设置
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
          // 分组筛选：对齐安卓 RssFragment 的分组菜单（linkedSetOf 保序聚合）
          PopupMenuButton<String?>(
            tooltip: '筛选',
            icon: const Icon(Icons.filter_list),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSourceDialog,
        icon: const Icon(Icons.add),
        label: const Text('添加源'),
      ),
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

          // 分组过滤后为空：提示当前分组无订阅源
          if (state.filteredSources.isEmpty) {
            return const EmptyState(
              icon: Icons.rss_feed,
              title: '当前分组暂无订阅源',
              simple: true,
            );
          }

          return RefreshIndicator(
            onRefresh: () => notifier.loadSources(),
            // 安卓端使用 GridLayoutManager spanCount=4
            // 响应式改造：按可用宽度动态计算列数（手机 2 列 / 中大屏 3 列 / 平板 4 列）
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    Responsive.gridColumnsForWidth(constraints.maxWidth);
                final aspectRatio =
                    Responsive.rssGridChildAspectRatio(constraints.maxWidth);
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    childAspectRatio: aspectRatio,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: state.filteredSources.length,
                  itemBuilder: (context, index) {
                    final source = state.filteredSources[index];
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
        // 安卓端 item 内边距，缩小至 8 避免 360dp 窄屏溢出
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 图标：50x50 圆角12dp（安卓端 FilletImageView radius=12dp）
            ClipRRect(
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

  /// 占位图标：显示源名称首字母
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
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}
