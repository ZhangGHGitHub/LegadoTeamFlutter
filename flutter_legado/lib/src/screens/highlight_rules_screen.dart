import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/md3_fast_scroller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/highlight_style.dart' show normalizeArgb;
import '../providers/highlight_rules/highlight_rules_notifier.dart';
import '../widgets/empty_state.dart';
import '../widgets/export_file_sheet.dart';
import '../widgets/loading_indicator.dart';

/// 高亮分组「未分组」筛选哨兵（key 统一加前缀，避免与用户组名冲突）
const String kHighlightUngroupedGroup = '__ungrouped__';

/// 保留分组名（不得作为用户分组；避免与筛选项语义冲突）
const Set<String> kHighlightReservedGroupNames = {
  kHighlightUngroupedGroup,
  'all',
  '全部',
};

bool isReservedHighlightGroupName(String name) =>
    kHighlightReservedGroupNames.contains(name);

/// 高亮规则导出 JSON（批7c-2：批量导出选中项复用）
///
/// 字段仍走 [HighlightRule.toExportJson]（uuid/order/timeout/applyToBody 保真）。
String buildHighlightRulesExportJson(List<HighlightRule> rules) {
  return const JsonEncoder.withIndent('  ').convert({
    'type': 'highlightRule',
    'rules': rules.map((r) => r.toExportJson()).toList(),
  });
}

/// 高亮规则管理页面
///
/// 对标 Android 原版 [HighlightRuleActivity]（ui/highlight/HighlightRuleActivity.kt）：
/// - 规则列表（按 sortOrder 升序，项内显示名称/模式 + 启用开关）
/// - 顶栏「+」新增规则（menu_add_highlight_rule）
/// - 编辑（HighlightRuleEditDialog）/ 删除（确认对话框 sure_del）
///
/// 数据经 BookApi highlightRule* 系列接口（Rust 侧 highlight_api）。
/// [审计修复 §4.3 第二批] JSON 解析已下沉至 HighlightRulesNotifier，
/// 本层仅消费类型化的 [HighlightRule] — Qoder
class HighlightRulesScreen extends ConsumerStatefulWidget {
  const HighlightRulesScreen({super.key});

  @override
  ConsumerState<HighlightRulesScreen> createState() =>
      _HighlightRulesScreenState();
}

class _HighlightRulesScreenState extends ConsumerState<HighlightRulesScreen> {
  // [UI_SYNC_REFACTOR R3] 快速滚动条控制器
  final ScrollController _fsController = ScrollController();

  // ===== [批7c-2] 批量选择 / 分组筛选 =====
  bool _batchMode = false;
  final Set<int> _selected = <int>{};
  String? _groupFilter; // null=全部；_ungrouped=未分组；其它=分组名
  static const String _ungrouped = kHighlightUngroupedGroup;
  bool _batchBusy = false;
  String? _batchError;

  @override
  void initState() {
    super.initState();
    // 首帧后加载，避免在 build 期间触发 notifier 状态写入
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(highlightRulesNotifierProvider.notifier).load();
    });
  }

  String _groupOf(HighlightRule rule) => rule.group?.trim() ?? '';

  List<String> _groupNames(List<HighlightRule> rules) {
    final set = <String>{};
    for (final rule in rules) {
      final group = _groupOf(rule);
      if (group.isNotEmpty) set.add(group);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// 当前筛选值收敛：分组已不存在时按「全部」展示（不产生假空态）
  String? _resolvedGroupFilter(List<HighlightRule> rules) {
    final filter = _groupFilter;
    if (filter == null || filter == _ungrouped) return filter;
    return _groupNames(rules).contains(filter) ? filter : null;
  }

  void _normalizeGroupFilter() {
    final rules = ref.read(highlightRulesNotifierProvider).rules;
    if (_groupFilter != null && _resolvedGroupFilter(rules) == null) {
      setState(() => _groupFilter = null);
    }
  }

  List<HighlightRule> _filteredRules(List<HighlightRule> rules) {
    final filter = _resolvedGroupFilter(rules);
    if (filter == null) return rules;
    return rules.where((rule) {
      final group = _groupOf(rule);
      return filter == _ungrouped ? group.isEmpty : group == filter;
    }).toList();
  }

  Set<int> _visibleSelection(List<HighlightRule> rules) {
    final visible = _filteredRules(rules).map((r) => r.id).toSet();
    return _selected.where(visible.contains).toSet();
  }

  void _enterBatch([HighlightRule? rule]) {
    setState(() {
      _batchMode = true;
      _batchError = null;
      if (rule != null) _selected.add(rule.id);
    });
  }

  void _exitBatch() {
    setState(() {
      _batchMode = false;
      _selected.clear();
      _batchError = null;
    });
  }

  void _toggleSelected(HighlightRule rule) {
    setState(() {
      _batchError = null;
      if (!_selected.add(rule.id)) _selected.remove(rule.id);
    });
  }

  void _selectAllVisible(List<HighlightRule> rules) {
    setState(() {
      _batchError = null;
      _selected
        ..clear()
        ..addAll(_filteredRules(rules).map((r) => r.id));
    });
  }

  void _invertVisible(List<HighlightRule> rules) {
    final visible = _filteredRules(rules).map((r) => r.id);
    setState(() {
      _batchError = null;
      for (final id in visible) {
        if (!_selected.add(id)) _selected.remove(id);
      }
    });
  }

  void _setGroupFilter(String? filter, List<HighlightRule> rules) {
    setState(() {
      _batchError = null;
      _groupFilter = filter;
      final visibleIds = _filteredRules(rules).map((r) => r.id).toSet();
      _selected.retainAll(visibleIds);
    });
  }

  /// 批量操作范围 = 当前分组筛选后的可见项 ∩ 已选（隐藏项不参与）
  List<HighlightRule> _selectedRules(List<HighlightRule> rules) {
    final ids = _visibleSelection(rules);
    return _filteredRules(rules).where((r) => ids.contains(r.id)).toList();
  }

  void _showBatchErrors(List<String> errors, String action) {
    if (!mounted) return;
    if (errors.isEmpty) {
      setState(() => _batchError = null);
      _showErrorIfAny();
      return;
    }
    setState(() => _batchError = null);
    final head = errors.take(3).join('；');
    final suffix = errors.length > 3 ? ' 等 ${errors.length} 条' : '';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$action失败：$head$suffix')));
  }

  Future<void> _batchSetEnabled(List<HighlightRule> rules, bool enabled) async {
    if (_batchBusy) return;
    final selected = _selectedRules(rules);
    if (selected.isEmpty) {
      _showBatchError('请先选择规则');
      return;
    }
    setState(() => _batchBusy = true);
    try {
      final errors = await ref
          .read(highlightRulesNotifierProvider.notifier)
          .batchSetEnabled(selected, enabled);
      _showBatchErrors(errors, enabled ? '启用' : '停用');
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _batchDelete(List<HighlightRule> rules) async {
    if (_batchBusy) return;
    final selected = _selectedRules(rules);
    if (selected.isEmpty) {
      _showBatchError('请先选择规则');
      return;
    }
    setState(() => _batchBusy = true);
    try {
      await _doBatchDelete(selected);
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _doBatchDelete(List<HighlightRule> selected) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除高亮规则'),
        content: Text('确定删除选中的 ${selected.length} 条规则吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('highlight-batch-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final errors = await ref
        .read(highlightRulesNotifierProvider.notifier)
        .batchDelete(selected);
    if (!mounted) return;
    final remaining = ref
        .read(highlightRulesNotifierProvider)
        .rules
        .map((rule) => rule.id)
        .toSet();
    setState(() {
      // 全成功 → 空；部分失败 → 仅保留仍存在的 id
      _selected.retainAll(remaining);
    });
    _showBatchErrors(errors, '删除');
    _normalizeGroupFilter();
  }

  void _showBatchError(String message) {
    if (!mounted) return;
    setState(() => _batchError = message);
  }

  Future<void> _showGroupManage() async {
    final error = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _HighlightGroupManageDialog(),
    );
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('分组操作失败：$error')));
    }
    _normalizeGroupFilter();
    _showErrorIfAny();
  }

  /// 删除确认（对标原版 alert(sure_del + displayName)）
  Future<void> _confirmDelete(HighlightRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('高亮规则'),
        content: Text('确定删除吗？\n${rule.displayName}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(highlightRulesNotifierProvider.notifier).deleteRule(rule);
    if (!mounted) return;
    _normalizeGroupFilter();
    _showErrorIfAny();
  }

  Future<void> _edit(HighlightRule? rule) async {
    final saved = await showModalBottomSheet<HighlightRule>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        // 键盘弹起时 sheet 随动
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _HighlightRuleEditSheet(rule: rule),
      ),
    );
    if (saved == null) return;
    await ref.read(highlightRulesNotifierProvider.notifier).saveRule(saved);
    if (!mounted) return;
    _normalizeGroupFilter();
    _showErrorIfAny();
  }

  /// notifier 状态中的错误提示到 UI（避免静默吞噬）
  void _showErrorIfAny() {
    final error = ref.read(highlightRulesNotifierProvider).error;
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('操作失败: $error')));
  }

  /// 导出全部高亮规则（批16e：接入统一导出目标 Sheet）
  ///
  /// 对齐原版 `HighlightRuleActivity.kt:145-157`（exportRules →
  /// `HighlightRuleFile(type = HighlightRuleFile.TYPE, rules = rules)` →
  /// HandleFileContract.EXPORT）：文件名 `HighlightRules.json`、
  /// `application/json`；`HighlightRuleFile.TYPE` 原版取 `"highlightRule"`
  /// （`data/entities/HighlightRule.kt:107`）。
  ///
  /// 单条导出（`rules` 省略）导出当前全部规则；批量模式传入选中项。
  /// 空列表按原版 `highlight_rule_empty` 语义提示。
  ///
  /// [批16e 回修 | P1-1] 导出必须保留完整字段（uuid / order /
  /// timeoutMillisecond / applyToBody）：原实现直接 `toJson()` 只输出
  /// 8 个字段，本应用关联导入会因 uuid 缺失抛「uuid 非法」，且用户设置的
  /// 正文高亮开关/匹配超时全部丢失。现统一走 [HighlightRule.toExportJson]
  /// （字段名对齐原版实体，`order` 为原版排序字段名），不再凭空生成 uuid。
  Future<void> _exportRules({List<HighlightRule>? rules}) async {
    final target = rules ?? ref.read(highlightRulesNotifierProvider).rules;
    if (target.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无高亮规则')));
      return;
    }
    final json = buildHighlightRulesExportJson(target);
    final result = await showExportFileSheet(
      context,
      content: json,
      fileName: 'HighlightRules.json',
      // 参考版 highlightRule 备份/上传文件名
      uploadFileName: 'highlightRule.json',
      subject: '导出高亮规则',
    );
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(highlightRulesNotifierProvider);
    return AppScaffold(
      topBar: _buildAppBar(state),
      bottomBar: _batchMode ? _buildBatchBottomBar() : null,
      body: Builder(
        builder: (context) {
          if (state.isLoading) {
            return const LoadingIndicator(message: '加载高亮规则...');
          }
          if (state.error != null) {
            return Center(child: Text('加载失败: ${state.error}'));
          }
          if (state.rules.isEmpty) {
            return const EmptyState(
              icon: Symbols.format_paint_rounded,
              title: '暂无高亮规则',
              subtitle: '点击右上角「+」新增自动高亮规则',
            );
          }
          final rules = _filteredRules(state.rules);
          return Column(
            children: [
              _buildGroupFilterBar(state.rules),
              Expanded(
                child: rules.isEmpty
                    ? const Center(child: Text('该分组暂无规则'))
                    : Md3FastScroller(
                        controller: _fsController,
                        child: ListView(
                          controller: _fsController,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                          children: [
                            Card(
                              child: Column(
                                children: [
                                  for (var i = 0; i < rules.length; i++) ...[
                                    if (i > 0)
                                      const Divider(height: 1, indent: 16),
                                    _buildRuleTile(context, rules[i]),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(HighlightRulesState state) {
    if (_batchMode) {
      return LegadoAppBar(
        leading: IconButton(
          key: const ValueKey('highlight-batch-close'),
          icon: const Icon(Icons.close),
          tooltip: '退出批量',
          onPressed: _exitBatch,
        ),
        title: Text(
          '已选 ${_selected.length} 项',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('highlight-batch-menu'),
            enabled: !_batchBusy,
            tooltip: '选择操作',
            icon: const Icon(Symbols.checklist_rounded),
            onSelected: (value) {
              if (value == 'selectAll') _selectAllVisible(state.rules);
              if (value == 'invert') _invertVisible(state.rules);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'selectAll', child: Text('全选')),
              PopupMenuItem(value: 'invert', child: Text('反选')),
            ],
          ),
          IconButton(
            key: const ValueKey('highlight-batch-enable'),
            tooltip: '启用选中',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.check_circle_rounded, size: 20),
            onPressed: _batchBusy
                ? null
                : () => _batchSetEnabled(state.rules, true),
          ),
          IconButton(
            key: const ValueKey('highlight-batch-disable'),
            tooltip: '停用选中',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.remove_circle_outline_rounded, size: 20),
            onPressed: _batchBusy
                ? null
                : () => _batchSetEnabled(state.rules, false),
          ),
          IconButton(
            key: const ValueKey('highlight-batch-delete'),
            tooltip: '删除选中',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.delete_rounded, size: 20),
            onPressed: _batchBusy ? null : () => _batchDelete(state.rules),
          ),
          IconButton(
            key: const ValueKey('highlight-batch-export'),
            tooltip: '导出选中',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.ios_share_rounded, size: 20),
            onPressed: _batchBusy
                ? null
                : () {
                    final selected = _selectedRules(state.rules);
                    if (selected.isEmpty) {
                      _showBatchError('请先选择规则');
                      return;
                    }
                    _exportRules(rules: selected);
                  },
          ),
        ],
      );
    }
    return LegadoAppBar(
      title: const Text('高亮规则'),
      actions: [
        IconButton(
          icon: const Icon(Symbols.add_rounded),
          tooltip: '新增规则',
          onPressed: () => _edit(null),
        ),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          icon: const Icon(Symbols.more_vert_rounded),
          onSelected: (value) {
            switch (value) {
              case 'export':
                _exportRules();
              case 'batch':
                _enterBatch();
              case 'groups':
                _showGroupManage();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'batch', child: Text('批量管理')),
            PopupMenuItem(value: 'groups', child: Text('管理分组')),
            PopupMenuItem(value: 'export', child: Text('导出规则')),
          ],
        ),
      ],
    );
  }

  Widget _buildBatchBottomBar() {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        key: const ValueKey('highlight-batch-count'),
        color: cs.surfaceContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Text(
              _batchBusy
                  ? '已选 ${_selected.length} 项 · 处理中…'
                  : '已选 ${_selected.length} 项',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (_batchError != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _batchError!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.error),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGroupFilterBar(List<HighlightRule> allRules) {
    final groups = _groupNames(allRules);
    final resolved = _resolvedGroupFilter(allRules);
    final entries = <(String?, String)>[
      (null, '全部'),
      (_ungrouped, '未分组'),
      for (final group in groups) (group, group),
    ];
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                key: ValueKey(
                  entry.$1 == null
                      ? 'highlight-group-filter-all'
                      : entry.$1 == _ungrouped
                      ? 'highlight-group-filter-ungrouped'
                      : 'highlight-group-filter-group-${entry.$1}',
                ),
                label: Text(entry.$2),
                selected: resolved == entry.$1,
                onSelected: (_) => _setGroupFilter(entry.$1, allRules),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRuleTile(BuildContext context, HighlightRule rule) {
    final cs = Theme.of(context).colorScheme;
    final scope = rule.scope ?? '';
    final group = _groupOf(rule);
    final selected = _selected.contains(rule.id);
    return InkWell(
      key: ValueKey('highlight-rule-tile-${rule.id}'),
      onTap: () => _batchMode ? _toggleSelected(rule) : _edit(rule),
      onLongPress: () => _batchMode ? _toggleSelected(rule) : _enterBatch(rule),
      child: Container(
        color: _batchMode && selected
            ? cs.secondaryContainer.withValues(alpha: 0.35)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (_batchMode)
                Checkbox(
                  key: ValueKey('highlight-select-${rule.id}'),
                  value: selected,
                  onChanged: (_) => _toggleSelected(rule),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: rule.isEnabled
                            ? cs.onSurface
                            : cs.onSurfaceVariant,
                      ),
                    ),
                    if (rule.name.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          rule.pattern,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          if (rule.isRegex)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '正则',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              scope.isNotEmpty ? '范围：$scope' : '全局生效',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (group.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '分组：$group',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: cs.secondary),
                        ),
                      ),
                  ],
                ),
              ),
              if (!_batchMode) ...[
                Switch(
                  value: rule.isEnabled,
                  onChanged: (v) async {
                    await ref
                        .read(highlightRulesNotifierProvider.notifier)
                        .toggleEnabled(rule, v);
                    _showErrorIfAny();
                  },
                ),
                IconButton(
                  icon: Icon(
                    Symbols.delete_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _confirmDelete(rule),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 高亮规则分组管理对话框（批7c-2）
///
/// - 分组由规则 `group` 聚合（空分组不出现）；
/// - 重命名：批量把该组规则 group 改为新名；新名已存在时自然合并；
/// - 删除：确认后把该组规则 group 置 null（规则保留）；
/// - 操作逐条 save，失败在对话框内汇总展示。
class _HighlightGroupManageDialog extends ConsumerStatefulWidget {
  const _HighlightGroupManageDialog();

  @override
  ConsumerState<_HighlightGroupManageDialog> createState() =>
      _HighlightGroupManageDialogState();
}

class _HighlightGroupManageDialogState
    extends ConsumerState<_HighlightGroupManageDialog> {
  String? _error;
  String? _lastError;
  bool _busy = false;

  void _close() => Navigator.pop(context, _lastError);

  Map<String, List<HighlightRule>> _groupMap(List<HighlightRule> rules) {
    final map = <String, List<HighlightRule>>{};
    for (final rule in rules) {
      final group = rule.group?.trim() ?? '';
      if (group.isEmpty) continue;
      map.putIfAbsent(group, () => []).add(rule);
    }
    return map;
  }

  void _showErrors(List<String> errors, String action) {
    if (!mounted) return;
    final message = errors.isEmpty
        ? null
        : errors.length > 3
        ? '$action失败 ${errors.length} 条：${errors.take(3).join('；')}'
        : '$action失败：${errors.join('；')}';
    setState(() {
      _busy = false;
      _error = message;
      _lastError = message;
    });
  }

  Future<String?> _askName(String initial) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          key: const ValueKey('highlight-group-rename-field'),
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('highlight-group-rename-confirm'),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // 对话框退场动画期间 TextField 仍持有 controller，延后一帧再释放
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    return result;
  }

  Future<void> _rename(String oldName, List<HighlightRule> rules) async {
    if (_busy) return;
    final input = await _askName(oldName);
    if (input == null || !mounted) return;
    final next = input.trim();
    if (next.isEmpty) {
      setState(() => _error = '分组名称不能为空');
      return;
    }
    if (isReservedHighlightGroupName(next)) {
      setState(() => _error = '分组名称不可使用保留名');
      return;
    }
    if (next == oldName) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final targets = rules
        .where((rule) => (rule.group?.trim() ?? '') == oldName)
        .map((rule) => rule.copyWith(group: next))
        .toList();
    final errors = await ref
        .read(highlightRulesNotifierProvider.notifier)
        .batchSaveRules(targets);
    _showErrors(errors, '重命名分组');
  }

  Future<void> _delete(String group, List<HighlightRule> rules) async {
    if (_busy) return;
    final targets = rules
        .where((rule) => (rule.group?.trim() ?? '') == group)
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分组'),
        content: Text('确定删除分组「$group」吗？\n${targets.length} 条规则将变为未分组（规则本身保留）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('highlight-group-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final errors = await ref
        .read(highlightRulesNotifierProvider.notifier)
        .batchSaveRules(targets.map((rule) => rule.withGroup(null)));
    _showErrors(errors, '删除分组');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rules = ref.watch(highlightRulesNotifierProvider).rules;
    final groups = _groupMap(rules);
    final names = groups.keys.toList()..sort();
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('管理分组')),
          IconButton(
            key: const ValueKey('highlight-group-manage-close'),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: _busy ? null : _close,
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (names.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('暂无分组')),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final name in names)
                        ListTile(
                          key: ValueKey('highlight-group-row-$name'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${groups[name]!.length} 条规则'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: ValueKey('highlight-group-rename-$name'),
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                tooltip: '重命名',
                                onPressed: _busy
                                    ? null
                                    : () => _rename(name, rules),
                              ),
                              IconButton(
                                key: ValueKey('highlight-group-delete-$name'),
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                  color: cs.error,
                                ),
                                tooltip: '删除分组',
                                onPressed: _busy
                                    ? null
                                    : () => _delete(name, rules),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const ValueKey('highlight-group-error'),
                style: TextStyle(color: cs.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _close, child: const Text('关闭')),
      ],
    );
  }
}

/// 高亮规则编辑底部面板
///
/// 对标原版 HighlightRuleEditDialog 字段：
/// name / pattern / isRegex / applyToTitle / scope / style（颜色选择）。
class _HighlightRuleEditSheet extends StatefulWidget {
  final HighlightRule? rule;

  const _HighlightRuleEditSheet({this.rule});

  @override
  State<_HighlightRuleEditSheet> createState() =>
      _HighlightRuleEditSheetState();
}

class _HighlightRuleEditSheetState extends State<_HighlightRuleEditSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _patternCtrl;
  late final TextEditingController _scopeCtrl;
  late final TextEditingController _groupCtrl;
  late bool _isRegex;
  late bool _applyToTitle;
  // 高亮颜色（ARGB int，写入 style JSON 的 textColor 通道）
  late int _color;

  /// 用户是否在本次编辑中主动选过颜色（批33b）
  ///
  /// 缺陷背景：build 里把 `_color == 0` 直接替换成主题默认色后保存，
  /// 「只打开编辑面板再保存」也会把原 style 的 textColor（含 0=关闭）
  /// 改写成主题色。现记录触碰标记：未触碰且原 style 已有 textColor 键
  /// 时原样保留，只有用户选色才写入新值。
  bool _colorTouched = false;

  // ─── [批7a] 富样式本地编辑态（只覆盖渲染层已支持的属性） ───────────────
  //
  // fill / underline / strike 的初值取自原 style；distance 不在 UI 编辑，
  // 保存时从原 underline 对象继承（见 _save）。bold/italic/fillShape
  // 会改字体度量或尚未渲染，本批不提供控件、保存时原样保留。
  //
  // [审查 P2-2/P3] 全部字段带 touched 标记：未触碰的 width/kind/color 与
  // underline/strike 键（含 `false`/数组/`true` 等非对象原值）不得因
  // 「只改名称/文字色」被重写或删除；只有用户主动编辑的属性才写回。
  late int _fill;
  bool _fillTouched = false;
  int _lastFillColor = 0;
  late bool _underlineEnabled;
  bool _underlineTouched = false;
  bool _underlineKindTouched = false;
  bool _underlineColorTouched = false;
  bool _underlineWidthTouched = false;
  late String _underlineKind;
  late int _underlineColor;
  late double _underlineWidth;
  late bool _strikeEnabled;
  bool _strikeTouched = false;
  bool _strikeColorTouched = false;
  late int _strikeColor;

  /// 下划线可选线型（与渲染层 highlight_span_builder 的 5 种映射一致）
  static const List<String> _underlineKinds = [
    'SOLID',
    'WAVY',
    'DASHED',
    'DOTTED',
    'DOUBLE',
  ];

  /// 预设高亮色（M3 语义色板，对标原版 HighlightColors 预设集）
  ///
  /// [UI_MD3_ALIGNMENT_PLAN.md Batch B B7] 由 iOS 静态命名色改为随主题
  /// 亮暗自适应的 8 色：4 container + 3 fixedDim + error，供色板与默认色共用
  static List<Color> _presetColors(ColorScheme cs) => [
    cs.primaryContainer,
    cs.secondaryContainer,
    cs.tertiaryContainer,
    cs.errorContainer,
    cs.primaryFixedDim,
    cs.secondaryFixedDim,
    cs.tertiaryFixedDim,
    cs.inversePrimary,
  ];

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameCtrl = TextEditingController(text: rule?.name ?? '');
    _patternCtrl = TextEditingController(text: rule?.pattern ?? '');
    _scopeCtrl = TextEditingController(text: rule?.scope ?? '');
    _groupCtrl = TextEditingController(text: rule?.group ?? '');
    _isRegex = rule?.isRegex ?? false;
    _applyToTitle = rule?.applyToTitle ?? false;
    // [审计修复 §4.1] style 非法时模型层回退 null，此处取默认色 — Qoder
    // [UI_MD3_ALIGNMENT_PLAN.md Batch B B7] 默认色延后至 build 由主题派生
    //（initState 无 context），0 表未初始化
    // [审查 P3] 统一归一化无符号 ARGB：原版 JSON 半透明色可能为负值，
    // 不归一化会导致色板选中态与 Color 比较失配（仅影响本地态，原值
    // 未触碰时仍按原 JSON 保留）。
    _color = normalizeArgb(rule?.styleTextColor);

    // [批7a] 富样式初值（非法/缺省按关闭/默认值处理）
    final styleMap = rule?.styleMap;
    _fill = normalizeArgb(rule?.styleFill);
    _lastFillColor = _fill;
    _underlineEnabled = rule?.styleUnderline ?? false;
    final underlineRaw = styleMap?['underline'];
    final underlineMap = underlineRaw is Map
        ? underlineRaw.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};
    _underlineKind = _normalizeUnderlineKind(underlineMap['kind']);
    _underlineColor = normalizeArgb(underlineMap['color']);
    final rawWidth = underlineMap['width'];
    // 上游 HighlightStyle.width 是连续 Float（MIN 0 / MAX 10），不是 0.5
    // 步进；Slider 仅提供 0.5 的输入粒度，读取/写回不做量化。上游语义
    // width=0 = 不画线（渲染层已对齐：width<=0 不加下划线装饰）。
    _underlineWidth = (rawWidth is num ? rawWidth.toDouble() : 1.0).clamp(
      0.0,
      10.0,
    );
    final strikeRaw = styleMap?['strike'];
    _strikeEnabled = strikeRaw is Map;
    _strikeColor = strikeRaw is Map ? normalizeArgb(strikeRaw['color']) : 0;
  }

  static String _normalizeUnderlineKind(Object? raw) {
    if (raw is String) {
      final upper = raw.toUpperCase();
      if (_underlineKinds.contains(upper)) return upper;
    }
    return 'SOLID';
  }

  static String _underlineKindLabel(String kind) => switch (kind) {
    'WAVY' => '波浪',
    'DASHED' => '虚线',
    'DOTTED' => '点线',
    'DOUBLE' => '双线',
    _ => '实线',
  };

  static TextDecorationStyle _underlineDecorationStyle(String kind) =>
      switch (kind) {
        'WAVY' => TextDecorationStyle.wavy,
        'DASHED' => TextDecorationStyle.dashed,
        'DOTTED' => TextDecorationStyle.dotted,
        'DOUBLE' => TextDecorationStyle.double,
        _ => TextDecorationStyle.solid,
      };

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _scopeCtrl.dispose();
    _groupCtrl.dispose();
    super.dispose();
  }

  /// 组装保存模型（字段名与 Rust HighlightRule serde 契约一致）
  void _save() {
    final pattern = _patternCtrl.text.trim();
    if (pattern.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('匹配模式不能为空')));
      return;
    }
    if (_isRegex) {
      try {
        RegExp(pattern);
      } catch (_) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正则表达式无效，请检查')));
        return;
      }
    }
    final scope = _scopeCtrl.text.trim();
    final group = _groupCtrl.text.trim();
    if (group.isNotEmpty && isReservedHighlightGroupName(group)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('分组名称不可使用保留名')));
      return;
    }
    final base = widget.rule;
    final baseStyle = base?.styleMap;
    // [批16e 回修 | P1-1] 编辑保存保留 uuid/order/超时/正文开关：
    // 缺失 uuid 会让 Rust 每次保存都重新生成身份，导入去重随之失效。
    // [批28/7c-2] group 由编辑表单输入；空值转 null，其余 trim 后原样保存。
    // [批33b | 未触碰保真] 未主动选色且原 style 已含 textColor（含 0=关闭）
    // 时原样保留，避免「打开编辑再保存」把用户/原版设置改写成主题色。
    final keepOriginalTextColor =
        !_colorTouched && (baseStyle?.containsKey('textColor') ?? false);
    // [批7a] 富样式补丁：只写本地编辑态覆盖的属性，其余键（fillShape/bold/
    // italic/font* etc.）由补丁函数原样保留；distance 从原 underline 对象继承。
    // [审查 P2-2/P3] 未触碰的 underline/strike 键不写不删（保留原值形态，
    // 含 false/数组/true）；width/kind/color 各自按 touched 写，未触碰的
    // width（如 8 或 0）不会被 clamp 后的本地值静默覆盖。若用户编辑了该组
    // 但原对象缺少子键，则补全必要默认子键（kind/color/width）。
    final baseUnderline = _baseObjectField(baseStyle, 'underline');
    final baseStrike = _baseObjectField(baseStyle, 'strike');
    final underline = _underlineEnabled
        ? (<String, dynamic>{
            ...?baseUnderline,
            if (_underlineKindTouched || baseUnderline?['kind'] == null)
              'kind': _underlineKind,
            if (_underlineColorTouched || baseUnderline?['color'] == null)
              'color': _underlineColor,
            if (_underlineWidthTouched || baseUnderline?['width'] == null)
              'width': _underlineWidth,
          })
        : null;
    final strike = _strikeEnabled
        ? (<String, dynamic>{
            ...?baseStrike,
            if (_strikeColorTouched || baseStrike?['color'] == null)
              'color': _strikeColor,
          })
        : null;
    final style = mergeHighlightStyleFields(
      base?.style,
      // 未触碰填充时不写键（保留原缺省/原值）；关闭开关会置 touched 并写 fill=0
      fill: _fillTouched ? _fill : null,
      textColor: keepOriginalTextColor ? null : _effectiveColor,
      underline: underline,
      removeUnderline: _underlineTouched && !_underlineEnabled,
      strike: strike,
      removeStrike: _strikeTouched && !_strikeEnabled,
    );
    final rule = HighlightRule(
      id: base?.id ?? 0,
      uuid: base?.uuid ?? '',
      name: _nameCtrl.text.trim(),
      pattern: pattern,
      isRegex: _isRegex,
      applyToTitle: _applyToTitle,
      scope: scope.isEmpty ? null : scope,
      isEnabled: base?.isEnabled ?? true,
      style: style,
      sortOrder: base?.sortOrder ?? 0,
      timeoutMillisecond:
          base?.timeoutMillisecond ?? HighlightRule.defaultTimeoutMilliseconds,
      group: group.isEmpty ? null : group,
      applyToBody: base?.applyToBody ?? true,
    );
    Navigator.pop(context, rule);
  }

  /// 取 style 中某个嵌套对象字段的浅拷贝（非对象/缺省返回 null）
  static Map<String, dynamic>? _baseObjectField(
    Map<String, dynamic>? style,
    String key,
  ) {
    final raw = style?[key];
    if (raw is! Map) return null;
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  /// 当前生效的高亮色：未选色时用主题默认色（仅预览/新规则落库使用）
  int get _effectiveColor => _color != 0
      ? _color
      : _presetColors(Theme.of(context).colorScheme).first.toARGB32();

  /// 通用色板（批7a）：8 个主题色块 + 可选「跟随文字色」(0)
  ///
  /// 统一走 Wrap 适配窄屏（沿用批33b 的 360dp 溢出修复形态）；[key] 供
  /// widget 测试按区域定位色板，避免多组色板互相干扰。
  Widget _buildColorPalette({
    required Key key,
    required ColorScheme cs,
    required List<Color> colors,
    required int selected,
    required ValueChanged<int> onSelected,
    bool includeFollowTextColor = false,
  }) {
    return Wrap(
      key: key,
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (includeFollowTextColor)
          ChoiceChip(
            label: const Text('跟随文字色'),
            selected: selected == 0,
            onSelected: (_) => onSelected(0),
          ),
        for (final color in colors)
          GestureDetector(
            onTap: () => onSelected(color.toARGB32()),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected == color.toARGB32()
                      ? cs.primary
                      : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 「背景填充」开关：关闭写 fill=0；再次开启恢复上次自定义色
  ///
  /// [审查 P3] 关-开保留 `_lastFillColor`（此前会回落到 primaryContainer，
  /// 用户刚选的颜色被丢弃）；首次开启且无历史色时才用主题 primaryContainer。
  void _toggleFill(bool enabled, ColorScheme cs) {
    setState(() {
      _fillTouched = true;
      if (!enabled) {
        if (_fill != 0) _lastFillColor = _fill;
        _fill = 0;
      } else {
        _fill = _lastFillColor != 0
            ? _lastFillColor
            : cs.primaryContainer.toARGB32();
        _lastFillColor = _fill;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // [UI_MD3_ALIGNMENT_PLAN.md Batch B B7] 默认高亮色由当前主题派生
    final presetColors = _presetColors(cs);
    // [批33b | 未触碰保真] 不再把 `_color == 0` 改写进字段（原实现会在
    // 保存时把 0 落成主题色）；预览与色块选中态改用「有效色」，字段值
    // 只在用户主动选色时变更。
    final effectiveColor = _color != 0 ? _color : presetColors.first.toARGB32();
    // [批33 | 高亮字段保真] bold/italic 无编辑控件且渲染层不改字体度量，
    // 预览仅回放原值；fill/underline/strike 改用本地编辑态实时预览（批7a）。
    final baseStyle = widget.rule;
    final bold = baseStyle?.styleBold ?? false;
    final italic = baseStyle?.styleItalic ?? false;
    final underlineDecorationStyle = _underlineDecorationStyle(_underlineKind);
    // [审查 P3] 预览与渲染层同口径：width=0 视为不画线
    final previewUnderlineActive = _underlineEnabled && _underlineWidth > 0;
    final previewLineColor = previewUnderlineActive
        ? (_underlineColor != 0
              ? Color(_underlineColor)
              : Color(effectiveColor))
        : (_strikeEnabled
              ? (_strikeColor != 0
                    ? Color(_strikeColor)
                    : Color(effectiveColor))
              : null);
    final previewDecorations = <TextDecoration>[
      if (previewUnderlineActive) TextDecoration.underline,
      if (_strikeEnabled) TextDecoration.lineThrough,
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.rule == null ? '新增高亮规则' : '编辑高亮规则',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '规则名称（可选）',
                filled: true,
              ),
            ),
            const SizedBox(height: 12),
            // [LAYOUT_PLAN P1] 编辑区字段分组间距 12dp
            TextField(
              controller: _patternCtrl,
              decoration: const InputDecoration(
                labelText: '匹配模式 *',
                hintText: '要自动高亮的文本或正则表达式',
                filled: true,
              ),
            ),
            const SizedBox(height: 4),
            // [LAYOUT_PLAN P1] 开关行无 Chevron（SwitchListTile 自带无箭头，
            // 等价 showChevron=false）；标题字级走 M3 Type Scale
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用正则表达式'),
              value: _isRegex,
              onChanged: (v) => setState(() => _isRegex = v),
            ),
            // [LAYOUT_PLAN P1] 同上：开关行无 Chevron，等价 showChevron=false
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('应用到标题'),
              value: _applyToTitle,
              onChanged: (v) => setState(() => _applyToTitle = v),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _scopeCtrl,
              decoration: const InputDecoration(
                labelText: '生效范围（可选）',
                hintText: '书名或书源名，留空为全局生效',
                filled: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('highlight-rule-group'),
              controller: _groupCtrl,
              decoration: const InputDecoration(
                labelText: '分组（可选）',
                hintText: '留空为未分组',
                filled: true,
              ),
            ),
            const SizedBox(height: 16),
            Text('高亮颜色', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            // [窄屏溢出修复 | 2026-10-01] 原 Row 固定色块行（8×32dp 色块 +
            // 每块右侧 10dp = 336dp）在 360dp 设备上超出内容可用宽 320dp，
            // 实机报 RIGHT OVERFLOWED BY 16 PIXELS（MuMu 取证
            // .tmp/b3_ours_hl_dialog.png）。改 Wrap 换行，形态对齐项目内
            // 色板先例（theme_config_screen.dart _showColorPicker、
            // reader_settings_sheet.dart 自定义配色）：色块与间距等宽 =
            // 8×32 + 7×8 = 312dp ≤ 320dp，360dp 上仍单行，更窄时自动换行。
            _buildColorPalette(
              key: const Key('highlight-text-colors'),
              cs: cs,
              colors: presetColors,
              selected: _color,
              onSelected: (value) => setState(() {
                _color = value;
                _colorTouched = true;
              }),
            ),
            const SizedBox(height: 8),
            // ─── [批7a] 背景填充（fill，0=关闭） ─────────────────────────
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('背景填充'),
              value: _fill != 0,
              onChanged: (v) => _toggleFill(v, cs),
            ),
            if (_fill != 0)
              _buildColorPalette(
                key: const Key('highlight-fill-colors'),
                cs: cs,
                colors: presetColors,
                selected: _fill,
                onSelected: (value) => setState(() {
                  _fill = value;
                  _fillTouched = true;
                  _lastFillColor = value;
                }),
              ),
            const SizedBox(height: 4),
            // ─── [批7a] 下划线（kind/color/width；distance 保留不编辑） ──
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('下划线'),
              value: _underlineEnabled,
              onChanged: (v) => setState(() {
                _underlineEnabled = v;
                _underlineTouched = true;
              }),
            ),
            if (_underlineEnabled) ...[
              Row(
                children: [
                  Text('线型', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: _underlineKind,
                    isDense: true,
                    items: [
                      for (final kind in _underlineKinds)
                        DropdownMenuItem(
                          value: kind,
                          child: Text(_underlineKindLabel(kind)),
                        ),
                    ],
                    onChanged: (kind) {
                      if (kind == null) return;
                      setState(() {
                        _underlineKind = kind;
                        _underlineTouched = true;
                        _underlineKindTouched = true;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildColorPalette(
                key: const Key('highlight-underline-colors'),
                cs: cs,
                colors: presetColors,
                selected: _underlineColor,
                includeFollowTextColor: true,
                onSelected: (value) => setState(() {
                  _underlineColor = value;
                  _underlineTouched = true;
                  _underlineColorTouched = true;
                }),
              ),
              Row(
                children: [
                  Text('线宽', style: theme.textTheme.bodySmall),
                  Expanded(
                    child: Slider(
                      value: _underlineWidth,
                      // 上游 width 为连续 Float 0..10（0=不画线）；
                      // 0.5 仅作 Slider 输入粒度，读取/写回不量化
                      min: 0.0,
                      max: 10.0,
                      divisions: 20,
                      label: _underlineWidth.toStringAsFixed(1),
                      onChanged: (v) => setState(() {
                        _underlineWidth = v;
                        _underlineTouched = true;
                        _underlineWidthTouched = true;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${_underlineWidth.toStringAsFixed(1)} dp',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            // ─── [批7a] 删除线（strike.color；0=跟随文字色） ────────────
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('删除线'),
              value: _strikeEnabled,
              onChanged: (v) => setState(() {
                _strikeEnabled = v;
                _strikeTouched = true;
              }),
            ),
            if (_strikeEnabled)
              _buildColorPalette(
                key: const Key('highlight-strike-colors'),
                cs: cs,
                colors: presetColors,
                selected: _strikeColor,
                includeFollowTextColor: true,
                onSelected: (value) => setState(() {
                  _strikeColor = value;
                  _strikeTouched = true;
                  _strikeColorTouched = true;
                }),
              ),
            const SizedBox(height: 12),
            // 预览（批7a：实时使用本地编辑态，而非只回放旧 rule）
            Container(
              key: const Key('highlight-style-preview'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _fill != 0
                    ? Color(_fill)
                    : Color(effectiveColor).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '高亮效果预览',
                style: TextStyle(
                  color: Color(effectiveColor),
                  fontWeight: bold ? FontWeight.bold : null,
                  fontStyle: italic ? FontStyle.italic : null,
                  decoration: previewDecorations.isEmpty
                      ? null
                      : TextDecoration.combine(previewDecorations),
                  decorationColor: previewLineColor,
                  // 下划线线型/线宽实时联动（删除线保持默认线型）
                  decorationStyle: previewUnderlineActive
                      ? underlineDecorationStyle
                      : null,
                  decorationThickness: previewUnderlineActive
                      ? _underlineWidth
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _save,
                      child: const Text('保存'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
