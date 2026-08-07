import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/search/search_notifier.dart';

/// 搜索范围筛选面板（书源多选）
///
/// [UI-fix v2.0.3 | 2026-08-07] 分组选择改由搜索页锚定 PopupMenu 承担
/// （对齐原版溢出菜单分组列表：点选即生效、无需确定），本面板仅保留
/// 书源多选 Tab；弹窗初始高度由 0.6 加大至 0.9，避免列表截断 — Qoder
///
/// 对齐安卓端 SearchScopeDialog 的书源多选模式（Checkbox 多选 + 确定生效），
/// 筛选状态由 [SearchNotifier]（Riverpod）管理。
class SearchFilterPanel extends ConsumerStatefulWidget {
  const SearchFilterPanel({super.key});

  @override
  ConsumerState<SearchFilterPanel> createState() => _SearchFilterPanelState();

  /// 便捷入口：弹出筛选面板（初始高度 0.9，避免书源列表截断）
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => const SearchFilterPanel(),
      ),
    );
  }
}

class _SearchFilterPanelState extends ConsumerState<SearchFilterPanel> {
  List<BookSource> _sources = [];
  bool _loading = true;
  String? _error;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getEnabledBookSources();
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

  /// 按搜索关键字过滤后的书源列表
  List<BookSource> get _filteredSources {
    if (_searchQuery.isEmpty) return _sources;
    return _sources
        .where((s) =>
            s.bookSourceName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            s.bookSourceUrl.toLowerCase().contains(_searchQuery.toLowerCase()))
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 标题行（[UI-fix v2.0.3 | 2026-08-07] 分组 Tab 移除后仅余书源多选）— Qoder
            Row(
              children: [
                Text('选择书源', style: Theme.of(context).textTheme.titleMedium),
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                      : _buildSourceList(state),
            ),
            const SizedBox(height: 8),
            // 确定按钮（书源多选批量生效）
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

  /// 统计信息行（书源多选）
  Widget _buildStatsRow(SearchState state) {
    return Row(
      children: [
        Text(
          '已选择 ${state.selectedSourceUrls.length} / ${_sources.length} 个书源',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Spacer(),
        TextButton(
          onPressed: () {
            final notifier = ref.read(searchNotifierProvider.notifier);
            // 全选/取消全部书源
            if (state.selectedSourceUrls.length == _sources.length) {
              notifier.clearSourceFilter();
            } else {
              for (final source in _sources) {
                if (!state.selectedSourceUrls
                    .contains(source.bookSourceUrl)) {
                  notifier.toggleSource(source.bookSourceUrl);
                }
              }
            }
          },
          child: Text(_isAllSelected(state) ? '取消全选' : '全选'),
        ),
      ],
    );
  }

  bool _isAllSelected(SearchState state) {
    return _sources.isNotEmpty &&
        state.selectedSourceUrls.length == _sources.length;
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

  /// 书源列表（对齐安卓端 SearchScopeDialog 的书源多选模式）
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
