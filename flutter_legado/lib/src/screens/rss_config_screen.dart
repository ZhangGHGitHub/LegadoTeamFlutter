import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// RSS 订阅源管理页面
///
/// 对标 Android 端 RssSourceActivity.kt：
/// - 列表展示所有 RSS 源（名称、分组、启用状态）
/// - 搜索过滤
/// - 分组筛选
/// - 启用/禁用、编辑、删除
class RssConfigScreen extends ConsumerStatefulWidget {
  const RssConfigScreen({super.key});

  @override
  ConsumerState<RssConfigScreen> createState() => _RssConfigScreenState();
}

class _RssConfigScreenState extends ConsumerState<RssConfigScreen> {
  List<RssSource> _sources = [];
  bool _loading = true;
  String? _error;
  String _searchQuery = '';
  String? _selectedGroup;

  late final TextEditingController _searchCtrl;

  /// 安卓端 AppPattern.splitGroupRegex：[,;，；]
  static final RegExp _splitGroupRegex = RegExp(r'[,;，；]');

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSources();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ===== 数据加载 =====

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getRssSources();
      if (mounted) {
        setState(() {
          _sources = sources;
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

  // ===== 分组逻辑 =====

  /// 聚合所有源的分组，去重并保持插入顺序
  List<String> get _groups {
    final set = <String>{};
    for (final source in _sources) {
      set.addAll(_splitGroups(source.sourceGroup));
    }
    return set.toList();
  }

  List<String> _splitGroups(String? sourceGroup) {
    if (sourceGroup == null || sourceGroup.isEmpty) return const [];
    return sourceGroup
        .split(_splitGroupRegex)
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }

  /// 按搜索关键字 + 分组 + 启用状态过滤后的源列表
  List<RssSource> get _filteredSources {
    var result = _sources;

    // 启用/禁用过滤
    if (_filterEnabled) {
      result = result.where((s) => s.enabled).toList();
    } else if (_filterDisabled) {
      result = result.where((s) => !s.enabled).toList();
    }

    // 分组过滤
    final group = _selectedGroup;
    if (group != null) {
      result = result
          .where((s) => _splitGroups(s.sourceGroup).contains(group))
          .toList();
    }

    // 搜索过滤
    final query = _searchQuery.trim().toLowerCase();
    if (query.isNotEmpty) {
      result = result.where((s) {
        return s.sourceName.toLowerCase().contains(query) ||
            s.sourceUrl.toLowerCase().contains(query) ||
            (s.sourceGroup?.toLowerCase().contains(query) ?? false);
      }).toList();
    }

    return result;
  }

  // ===== CRUD 操作 =====

  Future<void> _toggleEnabled(RssSource source) async {
    final api = ref.read(bookApiProvider);
    try {
      if (source.enabled) {
        await api.disableRssSource(source.sourceUrl);
      } else {
        await api.enableRssSource(source.sourceUrl);
      }
      // 更新本地状态
      if (mounted) {
        setState(() {
          final index =
              _sources.indexWhere((s) => s.sourceUrl == source.sourceUrl);
          if (index != -1) {
            _sources[index] =
                _sources[index].copyWith(enabled: !source.enabled);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteSource(RssSource source) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除订阅源',
      content: '确定要删除「${source.sourceName}」吗？',
      confirmText: '删除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      final api = ref.read(bookApiProvider);
      await api.deleteRssSource(source.sourceUrl);
      if (mounted) {
        setState(() {
          _sources =
              _sources.where((s) => s.sourceUrl != source.sourceUrl).toList();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除「${source.sourceName}」')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  void _editSource(RssSource source) {
    Navigator.pushNamed(
      context,
      AppRoutes.rssSourceEdit,
      arguments: source,
    ).then((_) {
      // 编辑完成后刷新列表
      _loadSources();
    });
  }

  void _addSource() {
    Navigator.pushNamed(context, AppRoutes.rssSourceEdit).then((_) {
      // 新建完成后刷新列表
      _loadSources();
    });
  }

  // ===== UI 构建 =====

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: _showSearchDialog,
          ),
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'add', child: Text('新建订阅源')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'enabled', child: Text('只看已启用')),
              const PopupMenuItem(value: 'disabled', child: Text('只看已禁用')),
              const PopupMenuItem(value: 'all', child: Text('显示全部')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建订阅源',
        onPressed: _addSource,
        child: const Icon(Icons.add),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _sources.isEmpty) {
      return const LoadingIndicator(message: '加载订阅源...');
    }

    if (_error != null && _sources.isEmpty) {
      return ErrorView(
        message: _error!,
        onRetry: _loadSources,
      );
    }

    if (_sources.isEmpty) {
      return const EmptyState(
        icon: Icons.rss_feed,
        title: '暂无订阅源',
        subtitle: '点击右下角按钮新建订阅源',
      );
    }

    return Column(
      children: [
        // 搜索栏（当有搜索内容时显示）
        if (_searchQuery.isNotEmpty) _buildSearchBar(),
        // 分组筛选 Chip
        if (_groups.isNotEmpty) _buildGroupChips(),
        // 源列表
        Expanded(child: _buildSourceList()),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '搜索: $_searchQuery',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: '清除搜索',
            onPressed: () => setState(() => _searchQuery = ''),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupChips() {
    final groups = _groups;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: groups.length + 1, // +1 for "全部"
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              final selected = _selectedGroup == null;
              return FilterChip(
                label: const Text('全部'),
                selected: selected,
                onSelected: (_) => setState(() => _selectedGroup = null),
              );
            }
            final group = groups[index - 1];
            final selected = _selectedGroup == group;
            return FilterChip(
              label: Text(group),
              selected: selected,
              onSelected: (_) =>
                  setState(() => _selectedGroup = selected ? null : group),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSourceList() {
    final filtered = _filteredSources;

    if (filtered.isEmpty) {
      return const EmptyState(
        icon: Icons.rss_feed,
        title: '无匹配结果',
        simple: true,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadSources,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: filtered.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 60),
        itemBuilder: (context, index) {
          final source = filtered[index];
          return _buildSourceItem(source);
        },
      ),
    );
  }

  Widget _buildSourceItem(RssSource source) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.surfaceContainerHighest,
        child: Text(
          source.sourceName.isNotEmpty ? source.sourceName[0] : 'R',
          style: TextStyle(color: colorScheme.onSurface),
        ),
      ),
      title: Text(
        source.sourceName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: source.enabled ? null : colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
      subtitle: Text(
        source.sourceGroup ?? '未分组',
        style: theme.textTheme.bodySmall?.copyWith(
          color: source.enabled ? null : colorScheme.onSurface.withValues(alpha: 0.4),
        ),
      ),
      trailing: Switch(
        value: source.enabled,
        onChanged: (_) => _toggleEnabled(source),
      ),
      onTap: () => _editSource(source),
      onLongPress: () => _showSourceMenu(source),
    );
  }

  // ===== 弹窗/菜单 =====

  void _showSearchDialog() {
    final controller = TextEditingController(text: _searchQuery);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('搜索订阅源'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入名称或地址',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search),
          ),
          onSubmitted: (value) {
            Navigator.pop(dialogContext);
            setState(() => _searchQuery = value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              setState(() => _searchQuery = '');
            },
            child: const Text('清除'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              setState(() => _searchQuery = controller.text);
            },
            child: const Text('搜索'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSourceMenu(RssSource source) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(
                source.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
              ),
              title: Text(source.enabled ? '禁用' : '启用'),
              onTap: () => Navigator.pop(ctx, 'toggle'),
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(ctx).colorScheme.error),
              title: Text(
                '删除',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;

    switch (action) {
      case 'edit':
        _editSource(source);
      case 'toggle':
        _toggleEnabled(source);
      case 'delete':
        _deleteSource(source);
    }
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'add':
        _addSource();
      case 'enabled':
        setState(() {
          _searchQuery = '';
          _selectedGroup = null;
          _sources = _sources; // 保持原列表
          // 通过搜索过滤实现：只显示已启用
          _filterEnabled = true;
          _filterDisabled = false;
        });
      case 'disabled':
        setState(() {
          _searchQuery = '';
          _selectedGroup = null;
          _filterEnabled = false;
          _filterDisabled = true;
        });
      case 'all':
        setState(() {
          _searchQuery = '';
          _selectedGroup = null;
          _filterEnabled = false;
          _filterDisabled = false;
        });
    }
  }

  bool _filterEnabled = false;
  bool _filterDisabled = false;
}
