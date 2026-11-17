// search_screen.dart 的 part 文件（体检 §三.16 超长文件拆分）：
// 搜索范围底部弹层（顶层私有类原样搬移）。
part of 'search_screen.dart';

/// 搜索范围底部对话框视图（对齐原版 dialog_search_scope.xml）
///
/// 顶部 [分组 | 书源] 分段切换：分组模式 = CheckBox 多选；书源模式 =
/// RadioButton 单选 + 名称过滤字段。底栏：全部书源（清空为全量）|
/// 取消 | 确定（按 rb 语义应用）。iOS 风格：底部弹层、系统列表节奏、
/// 中性灰分段控件、克制的强调色 — Cursor UI
///
/// [设备验收缺陷 | 2026-11-17 批45b P2-1] 两处根因修复：
/// 1. **溢出**：旧实现把「标题 + 范围快捷节 + 分段 + 列表 + 底栏」放进
///    不可滚动的 Column，而 `showModalBottomSheet` 未开 `isScrollControlled`
///    （高度被钳到 9/16 屏）。小屏 / 大字号下固定块 + 底栏即超过可用高度：
///    RenderFlex 溢出，`Expanded` 列表被压成 0 高（书源列表整块消失、
///    无法勾选），底栏被挤出布局盒 —— 溢出带内的点按不再命中弹层而落到
///    遮罩层，直接把弹层关掉且不提交（设备上「点确定没反应」的真因）。
///    现改为：`isScrollControlled: true` + 内容区 `Expanded(SingleChildScrollView)`
///    + 底栏固定可见 + 底部安全区余量，任何字号下都不溢出、按钮始终可点。
/// 2. **勾选不生效**：旧实现让「范围快捷节」点按**立即**写 provider，而
///    复选框/单选只在「确定」提交 —— 两套时序并存导致：点快捷项后按「取消」
///    改动仍生效（取消形同虚设）、快捷节勾选态与应用态漂移、再次进入弹层
///    回显与实际筛选不一致。现统一为**单一暂存状态**：所有点按只改本地
///    `_checkedGroups` / `_selectedUrl`，「确定」一次性原子提交，「取消」
///    丢弃，快捷节勾选态直接由本地暂存态派生（勾选所见即所提交）。
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

  /// 全部不重复分组名（对标原版 BookSourceDao.dealGroups：
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

  /// 「确定」提交：把本地暂存态一次性原子写入 provider 后关闭。
  ///
  /// 分组模式 → [SearchNotifier.setGroups]（整体替换并清空书源筛选）；
  /// 书源模式 → 有选中走 [SearchNotifier.selectSourceOnly]（原子单源，
  /// 不用 toggle 语义以免「已选中再点」被解释成取消），未选中 = 全部书源。
  void _onOk() {
    final notifier = ref.read(searchNotifierProvider.notifier);
    if (_sourceMode) {
      final url = _selectedUrl;
      if (url == null) {
        notifier.clearAllFilter();
      } else {
        notifier.selectSourceOnly(url);
      }
    } else {
      notifier.setGroups(_checkedGroups.toList());
    }
    Navigator.of(context).pop();
  }

  /// 底栏「全部书源」：清空全部范围后关闭（等价于确定时无任何勾选）
  void _onAllSources() {
    ref.read(searchNotifierProvider.notifier).clearAllFilter();
    Navigator.of(context).pop();
  }

  /// 范围快捷：分组点按（点已选=取消、点未选=单选替换，与原 ⋮ 'group:X'
  /// 语义一致）。仅改本地暂存态，勾选态由 [build] 从暂存态派生，
  /// 保证「快捷节」与「复选框列表」两处勾选永不漂移。
  void _onQuickGroupTapped(String group) {
    setState(() {
      if (_checkedGroups.contains(group)) {
        // 已选 → 取消该组（对齐原 toggleGroup 的移除语义）
        _checkedGroups.remove(group);
      } else {
        // 未选 → 单选替换（对齐原 selectGroupExclusive）
        _checkedGroups = {group};
      }
      _selectedUrl = null;
    });
  }

  /// 范围快捷：当前书源点按 → 清除书源范围（对齐原 ⋮ '__current_source__'）
  void _onQuickCurrentSourceTapped() {
    setState(() => _selectedUrl = null);
  }

  /// 范围快捷：全部书源点按 → 清空本地暂存范围（对齐原 ⋮ '__all_sources__'）
  void _onQuickAllSourcesTapped() {
    setState(() {
      _checkedGroups = {};
      _selectedUrl = null;
    });
  }

  /// 当前选中书源名（快捷节展示用；多源取首名）
  String _quickCurrentSourceName(String? url) {
    if (url != null) {
      for (final s in widget.sources) {
        if (s.bookSourceUrl == url) return s.bookSourceName;
      }
    }
    return AppStrings.currentSource;
  }

  /// [1-6 ①] 范围快捷节（原 ⋮ 动态范围项并入 ◯ 弹层）：
  /// 当前书源（有书源范围时显示，勾选=点按清除）/ 全部书源 / 各分组
  ///（勾选=已选）；勾选态全部取自本地暂存态，重搜由
  /// `_showSearchScopeDialog` 关闭后的 changed 检测统一触发
  Widget _buildScopeQuickSection(ColorScheme scheme) {
    final rows = <Widget>[
      if (_selectedUrl != null)
        _quickRow(
          scheme,
          label: _quickCurrentSourceName(_selectedUrl),
          checked: true,
          onTap: _onQuickCurrentSourceTapped,
        ),
      _quickRow(
        scheme,
        label: AppStrings.allSources,
        checked: _selectedUrl == null && _checkedGroups.isEmpty,
        onTap: _onQuickAllSourcesTapped,
      ),
      for (final g in _groups)
        _quickRow(
          scheme,
          label: g,
          checked: _checkedGroups.contains(g),
          onTap: () => _onQuickGroupTapped(g),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: rows),
      ),
    );
  }

  /// 快捷节行：左勾选圈 + 名称（点按触发对应范围动作）
  Widget _quickRow(
    ColorScheme scheme, {
    required String label,
    required bool checked,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              checked ? Symbols.check_rounded : Symbols.circle_rounded,
              size: 18,
              color: checked ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

  /// 分组多选列表（暂存态；「确定」时才整体提交）
  Widget _buildGroupList(ColorScheme scheme) {
    if (_groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            AppStrings.noGroupedSource,
            style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5)),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final g in _groups)
          CheckboxListTile(
            title: Text(g),
            value: _checkedGroups.contains(g),
            onChanged: (v) => setState(() {
              if (v == true) {
                _checkedGroups.add(g);
                // 分组与书源互斥（对齐原版 rb_group / rb_source 单一范围）
                _selectedUrl = null;
              } else {
                _checkedGroups.remove(g);
              }
            }),
          ),
      ],
    );
  }

  /// 书源单选列表（暂存态；「确定」时才提交）
  Widget _buildSourceList(ColorScheme scheme) {
    final filtered = _filteredSources;
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            AppStrings.noMatchingSource,
            style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5)),
          ),
        ),
      );
    }
    return RadioGroup<String>(
      groupValue: _selectedUrl,
      onChanged: (v) => setState(() {
        _selectedUrl = v;
        // 书源与分组互斥（同上）
        _checkedGroups = {};
      }),
      child: Column(
        children: [
          for (final s in filtered)
            RadioListTile<String>(
              value: s.bookSourceUrl,
              title: Text(s.bookSourceName),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          // 内容区（标题/快捷节/分段/筛选框/列表）统一可滚动：小屏、横屏、
          // 大字号下内容超出可用高度时由滚动承载，不再挤爆 Column；
          // 底栏留在滚动区之外，任何情况下都完整可见、可点。
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('search-scope-scroll'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Text(
                      AppStrings.searchScope,
                      // [P1b] 17/w600 硬编码收敛至字阶 titleMedium（M3 区块标题）
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  // [1-6 ①] 范围快捷节（原 ⋮ 动态范围项并入 ◯ 弹层）
                  _buildScopeQuickSection(scheme),
                  const SizedBox(height: 12),
                  // 分段切换（原版 rg_scope：rb_group / rb_source）
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color:
                            scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Row(
                        children: [
                          _segmentButton(AppStrings.searchScopeGroup, !_sourceMode,
                              () => setState(() {
                            _sourceMode = false;
                          })),
                          const SizedBox(width: 3),
                          _segmentButton(AppStrings.searchScopeSource, _sourceMode,
                              () => setState(() {
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
                          hintText: AppStrings.searchSourceHint,
                          hintStyle: TextStyle(
                              fontSize: 14,
                              color: scheme.onSurface.withValues(alpha: 0.5)),
                          prefixIcon: Icon(Symbols.search_rounded, size: 20,
                              color: scheme.onSurface.withValues(alpha: 0.5)),
                          // [B3] 弹层内筛选框：三态显式无边框，防主题底线式渗入
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          filled: true,
                          fillColor:
                              scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _sourceMode
                        ? _buildSourceList(scheme)
                        : _buildGroupList(scheme),
                  ),
                ],
              ),
            ),
          ),
          // 底栏（原版 tv_all_source / tv_cancel / tv_ok）——固定在滚动区外
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                TextButton(
                  onPressed: _onAllSources,
                  child: Text(AppStrings.allSources, style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.7))),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(AppStrings.cancel, style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.7))),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _onOk,
                  child: Text(AppStrings.confirm, style: TextStyle(
                      color: scheme.primary, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
