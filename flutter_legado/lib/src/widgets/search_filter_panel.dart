import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/search_provider.dart';
import '../services/rust_api.dart';

/// 搜索源筛选面板
/// 
/// 以底部弹出面板形式展示所有可用的书源，支持多选
class SearchFilterPanel extends StatefulWidget {
  const SearchFilterPanel({super.key});

  @override
  State<SearchFilterPanel> createState() => _SearchFilterPanelState();

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

class _SearchFilterPanelState extends State<SearchFilterPanel> {
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
      final api = context.read<RustApi>();
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
    final provider = context.watch<SearchProvider>();
    final selectedUrls = provider.selectedSourceUrls;

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
            // 标题
            Row(
              children: [
                Text('选择搜索源', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (selectedUrls.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      provider.clearSourceFilter();
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
                hintText: '搜索书源...',
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
            Row(
              children: [
                Text(
                  '已选择 ${selectedUrls.length} / ${_sources.length} 个书源',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    // 全选/取消全选
                    if (selectedUrls.length == _sources.length) {
                      provider.clearSourceFilter();
                    } else {
                      for (final source in _sources) {
                        if (!selectedUrls.contains(source.bookSourceUrl)) {
                          provider.toggleSource(source.bookSourceUrl);
                        }
                      }
                    }
                  },
                  child: Text(selectedUrls.length == _sources.length ? '取消全选' : '全选'),
                ),
              ],
            ),
            const Divider(),
            // 书源列表
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.error_outline,
                                  size: 48, color: Theme.of(context).colorScheme.error),
                              const SizedBox(height: 8),
                              Text('加载失败',
                                  style: Theme.of(context).textTheme.bodyMedium),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: _loadSources,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : _filteredSources.isEmpty
                          ? Center(
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
                            )
                          : ListView.builder(
                              itemCount: _filteredSources.length,
                              itemBuilder: (context, index) {
                                final source = _filteredSources[index];
                                final isSelected = selectedUrls.contains(source.bookSourceUrl);
                                return CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: isSelected,
                                  onChanged: (value) {
                                    provider.toggleSource(source.bookSourceUrl);
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
                            ),
            ),
            const SizedBox(height: 8),
            // 确定按钮
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text('确定 (${selectedUrls.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
