import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/discover_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 书源发现页面
class SourceDiscoverScreen extends StatefulWidget {
  const SourceDiscoverScreen({super.key});

  @override
  State<SourceDiscoverScreen> createState() => _SourceDiscoverScreenState();
}

class _SourceDiscoverScreenState extends State<SourceDiscoverScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: DiscoverProvider.categories.length,
      vsync: this,
    );
    _tabController.addListener(_onTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DiscoverProvider>().loadSources();
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final provider = context.read<DiscoverProvider>();
      provider.setCategory(DiscoverProvider.categories[_tabController.index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DiscoverProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('书源发现'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: DiscoverProvider.categories
              .map((c) => Tab(text: c))
              .toList(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context),
          ),
        ],
      ),
      body: _buildBody(provider, theme),
    );
  }

  Widget _buildBody(DiscoverProvider provider, ThemeData theme) {
    if (provider.loading) {
      return const LoadingIndicator();
    }

    if (provider.error != null) {
      return ErrorView(
        message: provider.error!,
        onRetry: () => provider.loadSources(),
      );
    }

    final sources = provider.filteredSources;
    if (sources.isEmpty) {
      return const EmptyState(
        icon: Icons.explore_outlined,
        title: '暂无推荐书源',
      );
    }

    if (provider.filterKeyword.isNotEmpty) {
      return _buildFilteredSearchBar(provider, sources);
    }

    return _buildSourceList(provider, sources);
  }

  Widget _buildFilteredSearchBar(
      DiscoverProvider provider, List<RecommendedSource> sources) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索书源...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchController.clear();
                  provider.clearFilter();
                },
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: provider.setFilter,
          ),
        ),
        Expanded(child: _buildSourceList(provider, sources)),
      ],
    );
  }

  Widget _buildSourceList(
      DiscoverProvider provider, List<RecommendedSource> sources) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: sources.length,
      itemBuilder: (context, index) {
        return _SourceCard(
          source: sources[index],
          installed: provider.isInstalled(sources[index].source.bookSourceUrl),
          onInstall: () => _onInstall(provider, sources[index]),
          onUninstall: () =>
              _onUninstall(provider, sources[index].source.bookSourceUrl),
        );
      },
    );
  }

  Future<void> _onInstall(
      DiscoverProvider provider, RecommendedSource source) async {
    final ok = await provider.installSource(source);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已安装: ${source.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
    } else if (provider.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(provider.error!)),
      );
    }
  }

  Future<void> _onUninstall(
      DiscoverProvider provider, String sourceUrl) async {
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

  void _showSearchDialog(BuildContext context) {
    final provider = context.read<DiscoverProvider>();
    _searchController.text = provider.filterKeyword;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('搜索书源'),
          content: TextField(
            controller: _searchController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入书源名称或描述...',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: provider.setFilter,
          ),
          actions: [
            TextButton(
              onPressed: () {
                _searchController.clear();
                provider.clearFilter();
                Navigator.pop(ctx);
              },
              child: const Text('清除'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

/// 书源卡片
class _SourceCard extends StatelessWidget {
  final RecommendedSource source;
  final bool installed;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;

  const _SourceCard({
    required this.source,
    required this.installed,
    required this.onInstall,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // 图标
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _categoryIcon(source.category),
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        source.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (installed) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '已安装',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    source.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 操作按钮
            if (installed)
              OutlinedButton.icon(
                onPressed: onUninstall,
                icon: const Icon(Icons.remove_circle_outline, size: 18),
                label: const Text('卸载'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  side: BorderSide(color: colorScheme.error.withValues(alpha: 0.5)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              )
            else
              FilledButton.icon(
                onPressed: onInstall,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('安装'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _categoryIcon(String category) {
    switch (category) {
      case '精选':
        return Icons.star;
      case '小说':
        return Icons.menu_book;
      case '漫画':
        return Icons.image;
      case '新闻':
        return Icons.article;
      default:
        return Icons.source;
    }
  }
}
