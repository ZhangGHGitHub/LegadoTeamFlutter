import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/replace_rule/replace_rule_notifier.dart';
import '../widgets/custom_group_dialog.dart';
import 'source_import_confirm_screen.dart' show AppColorsExt;

/// 替换规则导入状态（对标原版 ImportReplaceRuleDialog 状态展示）
enum _ImportStatus {
  /// 新增（本地不存在同 id 规则）
  isNew,

  /// 更新（pattern/replacement/isRegex/scope 任一不同）
  isUpdate,

  /// 已有（内容一致）
  exists,
}

/// 替换规则导入确认页（对标原版 ImportReplaceRuleDialog）
///
/// 拉取/解析出的候选替换规则在此页供用户勾选确认后才写入数据库：
/// - 列表项：勾选框 + 名称(分组) + 新增/更新/已有 状态 + 打开（查看 JSON）
/// - 顶部菜单：自定义源分组 / 保留原名（对标 import_replace.xml；
///   原版保留原名仅持久化偏好，不在导入时应用）
/// - 底部：全选|取消全选（n/m）/ 取消 / 确认
/// - 确认后返回导入成功条数
class ReplaceRuleImportConfirmScreen extends ConsumerStatefulWidget {
  /// 候选替换规则原始 JSON 列表（保留原始 Map，未入库）
  final List<Map<String, dynamic>> raws;

  /// 本地现有替换规则（按 id 匹配做状态判定，对标
  /// compareImportedReplaceRules 的 findByIds）
  final List<ReplaceRule> localRules;

  const ReplaceRuleImportConfirmScreen({
    super.key,
    required this.raws,
    required this.localRules,
  });

  @override
  ConsumerState<ReplaceRuleImportConfirmScreen> createState() =>
      _ReplaceRuleImportConfirmScreenState();
}

class _ReplaceRuleImportConfirmScreenState
    extends ConsumerState<ReplaceRuleImportConfirmScreen> {
  late final Map<int, ReplaceRule> _localById = {
    for (final r in widget.localRules) r.id: r,
  };

  /// 候选规则类型化视图（单条解析失败为 null，勾选时跳过）
  late final List<ReplaceRule?> _parsed = [
    for (final raw in widget.raws) _parse(raw),
  ];

  late final List<bool> _selected = [
    // 原版默认选中策略（compareImportedReplaceRules）：
    // 本地无同 id 规则（新增）才默认选中
    for (final rule in _parsed) rule != null && _localById[rule.id] == null,
  ];

  // 菜单选项（对标 import_replace.xml：仅自定义分组 + 保留原名）
  bool _keepName = false;

  // 自定义源分组
  String? _groupName;
  bool _isAddGroup = false;

  bool _importing = false;

  ReplaceRule? _parse(Map<String, dynamic> raw) {
    try {
      return ReplaceRule.fromJson(raw);
    } catch (_) {
      // 单条解析失败容错（对标 ReplaceAnalyzer 逐条失败不中断）
      return null;
    }
  }

  _ImportStatus _statusOf(int index) {
    final rule = _parsed[index];
    if (rule == null) return _ImportStatus.isNew;
    final local = _localById[rule.id];
    if (local == null) return _ImportStatus.isNew;
    if (rule.pattern != local.pattern ||
        rule.replacement != local.replacement ||
        rule.isRegex != local.isRegex ||
        rule.scope != local.scope) {
      return _ImportStatus.isUpdate;
    }
    return _ImportStatus.exists;
  }

  /// 列表项名称（对标原版：group 非空时显示「名称(分组)」）
  String _displayName(int index) {
    final rule = _parsed[index];
    if (rule == null) return '(格式错误)';
    final group = rule.group?.trim() ?? '';
    return group.isEmpty ? rule.name : '${rule.name}($group)';
  }

  int get _selectCount {
    var count = 0;
    for (final b in _selected) {
      if (b) count++;
    }
    return count;
  }

  bool get _isSelectAll => _selected.every((b) => b);

  /// 确认导入：应用自定义分组后按 id 匹配入库
  /// （对标 ImportReplaceRuleViewModel.importSelect：
  /// Room insert 按主键 upsert → 本地同 id 走更新，否则新增）
  Future<void> _confirmImport() async {
    if (_selectCount == 0) return;
    setState(() => _importing = true);
    try {
      final group = _groupName?.trim();
      final api = ref.read(bookApiProvider);
      var success = 0;
      for (var i = 0; i < widget.raws.length; i++) {
        if (!_selected[i]) continue;
        final rule = _parsed[i];
        if (rule == null) continue;
        var target = rule;
        if (group != null && group.isNotEmpty) {
          if (_isAddGroup) {
            final groups = <String>{
              ...?rule.group
                  ?.split(',')
                  .map((g) => g.trim())
                  .where((g) => g.isNotEmpty),
              group,
            };
            target = target.copyWith(group: groups.join(','));
          } else {
            target = target.copyWith(group: group);
          }
        }
        try {
          if (_localById.containsKey(target.id)) {
            await api.updateReplaceRule(target);
          } else {
            await api.addReplaceRule(target);
          }
          success++;
        } catch (_) {
          // 单条入库失败跳过（对标原版逐条容错）
        }
      }
      await ref.read(replaceRuleNotifierProvider.notifier).load();
      if (mounted) Navigator.of(context).pop(success);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 自定义源分组弹窗（对标原版 alertCustomGroup）
  Future<void> _showCustomGroupDialog() async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => CustomGroupDialog(
        initialName: _groupName ?? '',
        initialAddGroup: _isAddGroup,
      ),
    );
    if (result == null || !mounted) return;
    final (name, addGroup) = result;
    setState(() {
      _groupName = name.isEmpty ? null : name;
      _isAddGroup = addGroup;
    });
  }

  /// 查看规则 JSON（对标原版 tvOpen → CodeDialog：
  /// 展示类型化规则；解析失败时展示原始 JSON）
  Future<void> _showRuleJson(int index) async {
    final rule = _parsed[index];
    final json = const JsonEncoder.withIndent('  ')
        .convert(rule?.toJson() ?? widget.raws[index]);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_displayName(index)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('已复制到剪贴板')),
                );
              }
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('导入替换规则'),
        actions: [
          // 自定义源分组（对标 menu_new_group，always 显示）
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: colorScheme.onPrimary,
            ),
            onPressed: _showCustomGroupDialog,
            child: Text(_groupName == null
                ? '自定义源分组'
                : '${_isAddGroup ? '+' : ''}$_groupName'),
          ),
          PopupMenuButton<String>(
            tooltip: '更多选项',
            // 菜单在顶栏下方展开，不覆盖顶栏
            position: PopupMenuPosition.under,
            onSelected: _handleMenu,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'keep_name',
                checked: _keepName,
                child: const Text('保留原名'),
              ),
            ],
          ),
        ],
      ),
      body: widget.raws.isEmpty
          ? const Center(child: Text('格式错误，未解析到替换规则'))
          : ListView.separated(
              itemCount: widget.raws.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 16),
              itemBuilder: (context, index) => _buildItem(index),
            ),
      // 底部操作区（对标 dialog_recycler_view：footerLeft / cancel / ok）
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.6),
              width: 0.5,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextButton(
                    onPressed: () {
                      final selectAll = _isSelectAll;
                      setState(() {
                        for (var i = 0; i < _selected.length; i++) {
                          _selected[i] = !selectAll;
                        }
                      });
                    },
                    child: Text(
                      _isSelectAll
                          ? '取消全选（$_selectCount/${widget.raws.length}）'
                          : '全选（$_selectCount/${widget.raws.length}）',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _importing
                      ? null
                      : () => Navigator.of(context).pop(0),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed:
                      _importing || _selectCount == 0 ? null : _confirmImport,
                  child: _importing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('确认'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleMenu(String value) {
    setState(() {
      switch (value) {
        case 'keep_name':
          // 对标原版：仅切换显示状态（原版持久化偏好，
          // importSelect 不应用该选项）
          _keepName = !_keepName;
      }
    });
  }

  /// 单个候选规则项（对标 item_source_import.xml：
  /// 勾选框 + 名称(分组) + 状态标签 + 打开按钮）
  Widget _buildItem(int index) {
    final status = _statusOf(index);
    final colorScheme = Theme.of(context).colorScheme;

    final (label, color) = switch (status) {
      _ImportStatus.isNew => ('新增', AppColorsExt.importNew(colorScheme)),
      _ImportStatus.isUpdate =>
        ('更新', AppColorsExt.importUpdate(colorScheme)),
      _ImportStatus.exists =>
        ('已有', colorScheme.onSurfaceVariant),
    };

    return InkWell(
      onTap: () => setState(() => _selected[index] = !_selected[index]),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Checkbox(
              value: _selected[index],
              onChanged: (v) =>
                  setState(() => _selected[index] = v ?? false),
            ),
            Expanded(
              child: Text(
                _displayName(index),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                style: TextStyle(fontSize: 13, color: color),
              ),
            ),
            TextButton(
              onPressed: () => _showRuleJson(index),
              child: const Text('打开'),
            ),
          ],
        ),
      ),
    );
  }
}
