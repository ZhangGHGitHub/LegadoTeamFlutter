// search_screen.dart 的 part 文件（体检 §三.16 超长文件拆分）：
// 搜索范围底部弹层（顶层私有类原样搬移）。
part of 'search_screen.dart';

/// 搜索范围底部对话框视图（对齐原版 dialog_search_scope.xml）
///
/// 顶部 [分组 | 书源] 分段切换：分组模式 = CheckBox 多选；书源模式 =
/// RadioButton 单选 + 名称过滤字段。底栏：全部书源（清空为全量）|
/// 取消 | 确定（按 rb 语义应用）。iOS 风格：底部弹层、系统列表节奏、
/// 中性灰分段控件、克制的强调色 — Cursor UI
class _SearchScopeSheet extends ConsumerStatefulWidget {
  final List<BookSource> sources;
  final Set<String> initialGroups;
  final String? initialSourceUrl;

  const _SearchScopeSheet({
    required this.sources,
    required this.initialGroups,
    this.initialSourceUrl,
  });

  @override
  ConsumerState<_SearchScopeSheet> createState() => _SearchScopeSheetState();
}

class _SearchScopeSheetState extends ConsumerState<_SearchScopeSheet> {
  bool _sourceMode = false;
  late Set<String> _checkedGroups;
  String? _selectedUrl;
  final _queryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 原版默认 rb_source；若当前已是书源范围则保持书源模式（对齐 tvOk 语义）
    _sourceMode = widget.initialSourceUrl != null;
    _checkedGroups = {...widget.initialGroups};
    _selectedUrl = widget.initialSourceUrl;
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  /// 全部不重复分组名（与 _SearchScreenState._extractGroups 同逻辑：
  /// splitGroupRegex 拆分 + 首现序去重）
  List<String> get _groups {
    final set = <String>{};
    for (final s in widget.sources) {
      final group = s.bookSourceGroup;
      if (group != null && group.isNotEmpty) {
        for (final part in group.split(_splitGroupRegex).map((p) => p.trim())) {
          if (part.isNotEmpty) set.add(part);
        }
      }
    }
    return set.toList();
  }

  /// 书源模式：按名称过滤（原版 toolbar SearchView 同名行为）
  List<BookSource> get _filteredSources {
    final q = _queryController.text.trim().toLowerCase();
    if (q.isEmpty) return widget.sources;
    return widget.sources
        .where((s) => s.bookSourceName.toLowerCase().contains(q))
        .toList();
  }

  void _onOk() {
    final notifier = ref.read(searchNotifierProvider.notifier);
    if (_sourceMode) {
      if (_selectedUrl != null) {
        // 单选替换（原版 selectSource → SearchScope(url)）；未变更则不动作
        final current = ref.read(searchNotifierProvider).selectedSourceUrls;
        if (!current.contains(_selectedUrl)) {
          notifier.toggleSource(_selectedUrl!);
        }
      } else {
        // 原版：selectSource == null → SearchScope(空串) 全量
        notifier.clearAllFilter();
      }
    } else {
      // 分组多选整体替换（原版 CheckBox 组 → SearchScope(selectGroups)）
      notifier.setGroups(_checkedGroups.toList());
    }
    Navigator.of(context).pop();
  }

  void _onAllSources() {
    ref.read(searchNotifierProvider.notifier).clearAllFilter();
    Navigator.of(context).pop();
  }

  /// 分段按钮（MD3 SegmentedButton 视觉：选中 secondaryContainer 底 +
  /// onSecondaryContainer 前景，未选中透明底）
  Widget _segmentButton(String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: selected
            ? scheme.secondaryContainer
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text(
            '搜索范围',
            // [P1b] 17/w600 硬编码收敛至字阶 titleMedium（M3 区块标题）
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.onSurface,
            ),
          ),
        ),
        // 分段切换（原版 rg_scope：rb_group / rb_source）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                _segmentButton('分组', !_sourceMode, () => setState(() {
                  _sourceMode = false;
                })),
                const SizedBox(width: 3),
                _segmentButton('书源', _sourceMode, () => setState(() {
                  _sourceMode = true;
                })),
              ],
            ),
          ),
        ),
        if (_sourceMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: TextField(
              controller: _queryController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索书源',
                hintStyle: TextStyle(
                    fontSize: 14, color: scheme.onSurface.withValues(alpha: 0.5)),
                prefixIcon: Icon(Symbols.search_rounded, size: 20,
                    color: scheme.onSurface.withValues(alpha: 0.5)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _sourceMode
                ? RadioGroup<String>(
                    groupValue: _selectedUrl,
                    onChanged: (v) => setState(() {
                      _selectedUrl = v;
                    }),
                    child: Column(
                      children: [
                        for (final s in _filteredSources)
                          RadioListTile<String>(
                            value: s.bookSourceUrl,
                            title: Text(s.bookSourceName),
                          ),
                        if (_filteredSources.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text('无匹配书源', style: TextStyle(
                                  color:
                                      scheme.onSurface.withValues(alpha: 0.5))),
                            ),
                          ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      for (final g in _groups)
                        CheckboxListTile(
                          title: Text(g),
                          value: _checkedGroups.contains(g),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _checkedGroups.add(g);
                            } else {
                              _checkedGroups.remove(g);
                            }
                          }),
                        ),
                      if (_groups.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text('无分组书源', style: TextStyle(
                                color: scheme.onSurface.withValues(alpha: 0.5))),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        // 底栏（原版 tv_all_source / tv_cancel / tv_ok）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              TextButton(
                onPressed: _onAllSources,
                child: Text('全部书源', style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.7))),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('取消', style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.7))),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _onOk,
                child: Text('确定', style: TextStyle(
                    color: scheme.primary, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
