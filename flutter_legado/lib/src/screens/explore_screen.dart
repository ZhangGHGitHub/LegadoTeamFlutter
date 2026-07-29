/// 书源探索页面（ExploreScreen）
/// 
/// 参考 Android 原版 ExploreFragment.kt 实现
/// 核心功能：
/// 1. 显示已安装的书源列表
/// 2. 支持实时搜索过滤
/// 3. 按分组筛选书源
/// 4. 一键安装/卸载书源（CRUD 操作）
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/explore_provider.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ExploreProvider>().loadBookSources();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ExploreProvider>();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context, provider),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => provider.refreshBookSources(),
          ),
        ],
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
      return const EmptyState(
        icon: Icons.library_books_outlined,
        title: '暂无书源',
        subtitle: '请先导入或添加书源',
      );
    }

    return Column(
      children: [
        // 分组选择器
        Container(
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
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: provider.filteredBookSources.length,
      itemBuilder: (context, index) {
        final source = provider.filteredBookSources[index];
        return _SourceCard(
          source: source,
          onEdit: () {},
          onUninstall: () => _onUninstall(provider, source.bookSourceUrl!),
        );
      },
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

  void _showSearchDialog(BuildContext context, ExploreProvider provider) {
    _searchController.text = provider.searchKeyword;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('搜索书源'),
          content: TextField(
            controller: _searchController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入书源名称或 URL...',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: provider.setSearchKeyword,
          ),
          actions: [
            TextButton(
              onPressed: () {
                _searchController.clear();
                provider.clearSearch();
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
  final dynamic source;
  final VoidCallback onEdit;
  final VoidCallback onUninstall;

  const _SourceCard({
    required this.source,
    required this.onEdit,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    // 提取书名和作者信息
    final bookName = source.bookSourceName ?? '未命名书源';
    final bookSourceComment = source.bookSourceComment ?? '';
    final url = source.bookSourceUrl ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(12),
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
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.source,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              // 信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bookName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (bookSourceComment.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        bookSourceComment,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      url,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 操作按钮
              OutlinedButton.icon(
                onPressed: onUninstall,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  side: BorderSide(color: colorScheme.error.withValues(alpha: 0.5)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
