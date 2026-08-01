import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/search/search_notifier.dart';

/// 搜索范围筛选面板
///
/// 对齐安卓端 SearchScopeDialog，支持两种筛选模式：
/// - 分组模式：按书源分组多选（Checkbox）
/// - 书源模式：按单个书源多选（Checkbox）
///
/// 筛选状态由 [SearchNotifier]（Riverpod）管理。
class SearchFilterPanel extends ConsumerStatefulWidget {
  const SearchFilterPanel({super.key});

  @override
  ConsumerState<SearchFilterPanel> createState() => _SearchFilterPanelState();

  /// 便捷入口：弹出筛选面板
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, scrollController) => const SearchFilterPanel(),
      ),
    );
  }
}

class _SearchFilterPanelState extends ConsumerState<SearchFilterPanel>
    with SingleTickerProviderStateMixin {
  List<BookSource> _sources = [];
  bool _loading = true;
  String? _error;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  late final TabController _tabController;

  /// 从书源列表中提取的所有分组名
  List<String> _groups = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // Tab 切换后刷新统计行与全选按钮状态
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _loadSources();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getEnabledBookSources();
      if (mounted) {
        setState(() {
          _sources = sources;
          _groups = _extractGroups(sources);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 从书源列表中提取所有不重复的分组名
  List<String> _extractGroups(List<BookSource> sources) {
    final groupSet = <String>{};
    for (final source in sources) {
      final group = source.bookSourceGroup;
      if (group != null && group.isNotEmpty) {
        // 书源分组可能包含多个组名（逗号分隔）
        final parts = group.split(RegExp(r'[,，]')).map((g) => g.trim());
        for (final g in parts) {
          if (g.isNotEmpty) groupSet.add(g);
        }
      }
    }
    final list = groupSet.toList()..sort();
    return list;
  }

  /// 按搜索关键字过滤后的书源列表
  List<BookSource> get _filteredSources {
    if (_searchQuery.isEmpty) return _sources;
    return _sources
        .where((s) =>
            s.bookSourceName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            s.bookSourceUrl.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  /// 按搜索关键字过滤后的分组列表
  List<String> get _filteredGroups {
    if (_searchQuery.isEmpty) return _groups;
    return _groups
        .where((g) => g.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchNotifierProvider);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部把手
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 标题行
            Row(
              children: [
                Text('搜索范围', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (state.hasFilter)
                  TextButton(
                    onPressed: () {
                      ref
                          .read(searchNotifierProvider.notifier)
                          .clearAllFilter();
                      Navigator.pop(context);
                    },
                    child: const Text('清除全部'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // Tab 切换：分组 / 书源
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: '分组'),
                Tab(text: '书源'),
              ],
            ),
            const SizedBox(height: 8),
            // 搜索框
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
            const SizedBox(height: 8),
            // 统计信息
            _buildStatsRow(state),
            const Divider(),
            // 内容区域
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _buildErrorView()
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildGroupList(state),
                            _buildSourceList(state),
                          ],
                        ),
            ),
            const SizedBox(height: 8),
            // 确定按钮
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 统计信息行
  Widget _buildStatsRow(SearchState state) {
    final isGroupTab = _tabController.index == 0;
    String info;
    if (isGroupTab) {
      info = '已选择 ${state.selectedGroups.length} / ${_groups.length} 个分组';
    } else {
      info = '已选择 ${state.selectedSourceUrls.length} / ${_sources.length} 个书源';
    }

    return Row(
      children: [
        Text(info, style: Theme.of(context).textTheme.bodySmall),
        const Spacer(),
        TextButton(
          onPressed: () {
            final notifier = ref.read(searchNotifierProvider.notifier);
            if (isGroupTab) {
              // 全选/取消全部分组
              if (state.selectedGroups.length == _groups.length) {
                notifier.clearGroupFilter();
              } else {
                for (final group in _groups) {
                  if (!state.selectedGroups.contains(group)) {
                    notifier.toggleGroup(group);
                  }
                }
              }
            } else {
              // 全选/取消全部书源
              if (state.selectedSourceUrls.length == _sources.length) {
                notifier.clearSourceFilter();
              } else {
                for (final source in _sources) {
                  if (!state.selectedSourceUrls.contains(source.bookSourceUrl)) {
                    notifier.toggleSource(source.bookSourceUrl);
                  }
                }
              }
            }
          },
          child: Text(_isAllSelected(state, isGroupTab) ? '取消全选' : '全选'),
        ),
      ],
    );
  }

  bool _isAllSelected(SearchState state, bool isGroupTab) {
    if (isGroupTab) {
      return _groups.isNotEmpty && state.selectedGroups.length == _groups.length;
    } else {
      return _sources.isNotEmpty &&
          state.selectedSourceUrls.length == _sources.length;
    }
  }

  /// 错误视图
  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline,
              size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 8),
          Text('加载失败', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loadSources,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  /// 分组列表（对齐安卓端 SearchScopeDialog 的分组模式）
  Widget _buildGroupList(SearchState state) {
    final filteredGroups = _filteredGroups;
    if (filteredGroups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off,
                size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              _groups.isEmpty ? '暂无书源分组' : '未找到匹配的分组',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: filteredGroups.length,
      itemBuilder: (context, index) {
        final group = filteredGroups[index];
        final isSelected = state.selectedGroups.contains(group);
        // 计算该分组下的书源数量
        final count = _countSourcesInGroup(group);
        return CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: isSelected,
          onChanged: (value) {
            ref.read(searchNotifierProvider.notifier).toggleGroup(group);
          },
          title: Text(
            group,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '$count 个书源',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          secondary: Icon(
            isSelected ? Icons.check_circle : Icons.circle_outlined,
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }

  /// 计算某个分组下的书源数量
  int _countSourcesInGroup(String group) {
    int count = 0;
    for (final source in _sources) {
      final sourceGroup = source.bookSourceGroup;
      if (sourceGroup != null && sourceGroup.isNotEmpty) {
        final parts = sourceGroup.split(RegExp(r'[,，]')).map((g) => g.trim());
        if (parts.contains(group)) count++;
      }
    }
    return count;
  }

  /// 书源列表（对齐安卓端 SearchScopeDialog 的书源模式）
  Widget _buildSourceList(SearchState state) {
    final filteredSources = _filteredSources;
    if (filteredSources.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text('未找到匹配的书源',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: filteredSources.length,
      itemBuilder: (context, index) {
        final source = filteredSources[index];
        final isSelected =
            state.selectedSourceUrls.contains(source.bookSourceUrl);
        return CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: isSelected,
          onChanged: (value) {
            ref
                .read(searchNotifierProvider.notifier)
                .toggleSource(source.bookSourceUrl);
          },
          title: Text(
            source.bookSourceName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            source.bookSourceUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          secondary: Icon(
            isSelected ? Icons.check_circle : Icons.circle_outlined,
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
