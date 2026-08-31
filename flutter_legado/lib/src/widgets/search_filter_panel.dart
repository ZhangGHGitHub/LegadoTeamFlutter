import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/search/search_notifier.dart';
import '../utils/error_message.dart';

/// 搜索范围筛选面板（书源单选）
///
/// [UI-fix v2.0.3 | 2026-08-07] 分组选择改由搜索页锚定 PopupMenu 承担
/// （对齐原版溢出菜单分组列表：点选即生效、无需确定），本面板仅保留
/// 书源单选 Tab；弹窗初始高度由 0.6 加大至 0.9，避免列表截断 — Qoder
///
/// 对齐安卓端 SearchScopeDialog 的书源单选模式（RadioButton selectSource），
/// 筛选状态由 [SearchNotifier]（Riverpod）管理。 — Cursor UI
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
          _error = errorMessage(e);
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
            // 标题行（[UI-fix v2.0.3 | 2026-08-07] 分组 Tab 移除后仅余书源单选）— Qoder
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
                    child: const Text('全部书源'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // 搜索框
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索...',
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Symbols.close_rounded, size: 20),
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
            // 确定按钮（书源单选确认关闭）
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

  /// 统计信息行（书源单选）
  Widget _buildStatsRow(SearchState state) {
    final selected = state.selectedSourceUrls.length;
    return Text(
      selected > 0 ? '已选择 1 个书源' : '未选择书源（搜索全部）',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  /// 错误视图
  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.error_rounded,
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

  /// 书源列表（对齐安卓端 SearchScopeDialog 的书源单选模式）— Cursor UI
  Widget _buildSourceList(SearchState state) {
    final filteredSources = _filteredSources;
    if (filteredSources.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.search_off_rounded,
                size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text('未找到匹配的书源',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
    }

    // 书源单选：Flutter ≥3.32 RadioGroup 祖先管理选中态（原 groupValue/onChanged 已废弃）
    return RadioGroup<String?>(
      groupValue: state.selectedSourceUrls.isEmpty
          ? null
          : state.selectedSourceUrls.first,
      onChanged: (value) {
        if (value != null) {
          ref.read(searchNotifierProvider.notifier).toggleSource(value);
        }
      },
      child: ListView.builder(
        itemCount: filteredSources.length,
        itemBuilder: (context, index) {
          final source = filteredSources[index];
          return RadioListTile<String?>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: source.bookSourceUrl,
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
          );
        },
      ),
    );
  }
}
