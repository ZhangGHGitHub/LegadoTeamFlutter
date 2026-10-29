/// 发现页源内容模式 - 分类选择底部弹层
///
/// 参考版依据：`legado-with-MD3/.../ui/widget/components/explore/ExploreKindSelectSheet.kt`
/// —— 顶部搜索框 + 分类列表（当前分类高亮/勾选），选中即切换分类并关闭。
///
/// 仅列出可加载的 URL 型分类（[loadableExploreMainKinds] 口径），
/// 控件型分类（toggle/select/button/text）不参与源内容模式的分类 Tab。
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/models.dart';
import '../providers/explore/explore_main_state.dart';

/// 打开分类选择弹层
///
/// 返回用户选中的分类（取消返回 null）。
Future<ExploreCategory?> showExploreKindSelectSheet({
  required BuildContext context,
  required List<ExploreCategory> kinds,
  required String selectedKey,
}) {
  return showModalBottomSheet<ExploreCategory>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) =>
        _ExploreKindSelectSheet(kinds: kinds, selectedKey: selectedKey),
  );
}

class _ExploreKindSelectSheet extends StatefulWidget {
  final List<ExploreCategory> kinds;
  final String selectedKey;

  const _ExploreKindSelectSheet({
    required this.kinds,
    required this.selectedKey,
  });

  @override
  State<_ExploreKindSelectSheet> createState() =>
      _ExploreKindSelectSheetState();
}

class _ExploreKindSelectSheetState extends State<_ExploreKindSelectSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keyword = _query.trim().toLowerCase();
    final filtered = keyword.isEmpty
        ? widget.kinds
        : widget.kinds
              .where(
                (k) =>
                    k.title.toLowerCase().contains(keyword) ||
                    (k.url ?? '').toLowerCase().contains(keyword),
              )
              .toList();

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '选择分类',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索分类',
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
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的分类',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final kind = filtered[index];
                        final selected =
                            exploreKindKey(kind) == widget.selectedKey;
                        return ListTile(
                          title: Text(
                            kind.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: selected
                                ? TextStyle(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  )
                                : null,
                          ),
                          trailing: selected
                              ? Icon(
                                  Symbols.check_rounded,
                                  color: colorScheme.primary,
                                )
                              : null,
                          selected: selected,
                          onTap: () => Navigator.of(context).pop(kind),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
