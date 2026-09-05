import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'legado_app_bar.dart';

/// [UI_SYNC_REFACTOR S1b] Dynamic 搜索行顶栏（对齐参考仓 DynamicTopAppBar）
///
/// 结构：标题文字 + 右侧搜索切换钮（actions 前置）+ bottomContent 搜索行
///（AnimatedSize+Fade 展开/收起，对齐 expandVertically+fadeIn 语义）；
/// 可追加常驻 bottom（如发现页 FilterChip 横滑条）。
/// 搜索行默认展开（原版对齐口径：发现/订阅搜索为主入口），可收起让位标题。
class DynamicSearchAppBar extends StatefulWidget implements PreferredSizeWidget {
  final String title;

  /// 副标题（对齐参考 DynamicTopAppBar subtitle：发现/订阅显示当前分组名）
  final String? subtitle;
  final List<Widget>? actions;
  final TextEditingController searchController;
  final String searchHint;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;
  final bool initialExpanded;

  /// 常驻 bottom（如发现 FilterChips 48dp 横滑条），位于搜索行之下
  final PreferredSizeWidget? persistentBottom;

  const DynamicSearchAppBar({
    super.key,
    required this.title,
    this.subtitle,
    required this.searchController,
    required this.searchHint,
    required this.onChanged,
    this.actions,
    this.onClear,
    this.initialExpanded = true,
    this.persistentBottom,
  });

  @override
  State<DynamicSearchAppBar> createState() => _DynamicSearchAppBarState();

  @override
  Size get preferredSize {
    final bottomH = (persistentBottom?.preferredSize.height ?? 0) + 56;
    return Size.fromHeight(kToolbarHeight + bottomH);
  }
}

class _DynamicSearchAppBarState extends State<DynamicSearchAppBar> {
  late bool _expanded = widget.initialExpanded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final searchRow = AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.fastOutSlowIn,
      alignment: Alignment.topCenter,
      child: !_expanded
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SearchBar(
                  controller: widget.searchController,
                  hintText: widget.searchHint,
                  constraints: const BoxConstraints(minHeight: 40),
                  elevation: const WidgetStatePropertyAll(0),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 12),
                  ),
                  leading: Icon(
                    Symbols.search_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  trailing: [
                    if (widget.searchController.text.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          Symbols.close_rounded,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                        onPressed: widget.onClear,
                      ),
                  ],
                onChanged: widget.onChanged,
              ),
            ),
    );

    return LegadoAppBar(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title),
          if (widget.subtitle != null)
            Text(
              widget.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
        ],
      ),
      actions: [
        // [UI_SYNC_REFACTOR S1b] 搜索切换钮（对齐参考 onSearchToggle）
        IconButton(
          tooltip: _expanded ? '收起搜索' : '展开搜索',
          icon: Icon(_expanded
              ? Symbols.search_off_rounded
              : Symbols.search_rounded),
          onPressed: () => setState(() => _expanded = !_expanded),
        ),
        ...?widget.actions,
      ],
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(
          (widget.persistentBottom?.preferredSize.height ?? 0) + 52,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            searchRow,
            if (widget.persistentBottom != null) widget.persistentBottom!,
          ],
        ),
      ),
    );
  }
}
