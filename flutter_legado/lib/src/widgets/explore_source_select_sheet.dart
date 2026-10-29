/// 发现页源内容模式 - 书源选择底部弹层
///
/// 参考版依据：`legado-with-MD3/.../feature/explore/ExploreSourceSelectSheet.kt`
/// —— 顶部布局控件（列表/网格 + 网格列数）、搜索框、书源列表（当前源高亮），
/// 选中后立即切源并关闭。
///
/// 本实现额外提供「分组」筛选条（本批验收要求：搜索/分组/布局列数），
/// 分组为弹层内局部筛选，不改写发现源列表页的全局分组选择。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../models/models.dart';
import '../providers/explore/explore_main_notifier.dart';
import '../providers/explore/explore_main_state.dart';
import '../providers/explore/explore_notifier.dart';

/// 打开书源选择弹层
Future<void> showExploreSourceSelectSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => const _ExploreSourceSelectSheet(),
  );
}

class _ExploreSourceSelectSheet extends ConsumerStatefulWidget {
  const _ExploreSourceSelectSheet();

  @override
  ConsumerState<_ExploreSourceSelectSheet> createState() =>
      _ExploreSourceSelectSheetState();
}

class _ExploreSourceSelectSheetState
    extends ConsumerState<_ExploreSourceSelectSheet> {
  final _searchController = TextEditingController();
  String _query = '';
  String _group = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final explore = ref.watch(exploreNotifierProvider);
    final main = ref.watch(exploreMainNotifierProvider);
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final gridCount = main.gridCountFor(landscape: landscape);

    final groups = explore.groups.toList()..sort();
    final sources = _filterSources(explore.bookSources);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '选择书源',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // 布局控件：列表/网格切换 + 网格列数（对齐参考版 sheet 顶部）
            // 窄屏（<360dp）下 Row 会因两段控件最小宽度之和溢出，改为 Wrap
            // 换行排布；常规宽度保持「切换段占满 + 列数步进器靠右」。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final segmented = SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment<bool>(
                        value: false,
                        icon: Icon(Symbols.view_list_rounded, size: 18),
                        label: Text('列表'),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        icon: Icon(Symbols.grid_view_rounded, size: 18),
                        label: Text('网格'),
                      ),
                    ],
                    selected: {main.gridMode},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) => ref
                        .read(exploreMainNotifierProvider.notifier)
                        .setGridMode(selection.first),
                  );
                  final stepper = _GridCountStepper(
                    count: gridCount,
                    onChanged: (value) => ref
                        .read(exploreMainNotifierProvider.notifier)
                        .setGridCount(value, landscape: landscape),
                  );
                  if (constraints.maxWidth < 360) {
                    return Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        segmented,
                        if (main.gridMode) stepper,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: segmented),
                      if (main.gridMode) ...[
                        const SizedBox(width: 12),
                        stepper,
                      ],
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索书源（名称/地址）',
                  isDense: true,
                  prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除',
                          icon: const Icon(Symbols.close_rounded, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(height: 8),
            // 分组筛选条
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _GroupChip(
                    label: '全部',
                    selected: _group.isEmpty,
                    onTap: () => setState(() => _group = ''),
                  ),
                  for (final group in groups)
                    _GroupChip(
                      label: group,
                      selected: _group == group,
                      onTap: () => setState(() => _group = group),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: sources.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的书源',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: sources.length,
                      itemBuilder: (context, index) {
                        final source = sources[index];
                        final selected =
                            source.bookSourceUrl == main.selectedSourceUrl;
                        return ListTile(
                          leading: Icon(
                            Symbols.book_rounded,
                            color: selected
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            source.bookSourceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: (source.groupName ?? '').isEmpty
                              ? null
                              : Text(
                                  source.groupName!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: selected
                              ? Icon(
                                  Symbols.check_rounded,
                                  color: colorScheme.primary,
                                )
                              : null,
                          selected: selected,
                          onTap: () {
                            ref
                                .read(exploreMainNotifierProvider.notifier)
                                .selectSource(source.bookSourceUrl);
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<BookSource> _filterSources(List<BookSource> sources) {
    final keyword = _query.trim().toLowerCase();
    return sources.where((s) {
      if (_group.isNotEmpty && (s.groupName ?? '未分类') != _group) {
        return false;
      }
      if (keyword.isEmpty) return true;
      return s.bookSourceName.toLowerCase().contains(keyword) ||
          s.bookSourceUrl.toLowerCase().contains(keyword);
    }).toList();
  }
}

class _GroupChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _GroupChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

/// 网格列数步进器（1..10，含当前值）
class _GridCountStepper extends StatelessWidget {
  final int count;
  final ValueChanged<int> onChanged;

  const _GridCountStepper({required this.count, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '减少列数',
          visualDensity: VisualDensity.compact,
          onPressed: count <= exploreGridCountMin
              ? null
              : () => onChanged(count - 1),
          icon: const Icon(Symbols.remove_rounded, size: 18),
        ),
        Text('$count 列', style: theme.textTheme.labelLarge),
        IconButton(
          tooltip: '增加列数',
          visualDensity: VisualDensity.compact,
          onPressed: count >= exploreGridCountMax
              ? null
              : () => onChanged(count + 1),
          icon: const Icon(Symbols.add_rounded, size: 18),
        ),
      ],
    );
  }
}
