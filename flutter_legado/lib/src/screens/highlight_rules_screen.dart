import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../theme/app_colors.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_indicator.dart';

/// 高亮规则管理页面
///
/// 对标 Android 原版 [HighlightRuleActivity]（ui/highlight/HighlightRuleActivity.kt）：
/// - 规则列表（按 sortOrder 升序，项内显示名称/模式 + 启用开关）
/// - 顶栏「+」新增规则（menu_add_highlight_rule）
/// - 编辑（HighlightRuleEditDialog）/ 删除（确认对话框 sure_del）
///
/// 数据经 BookApi highlightRule* 系列接口（Rust 侧 highlight_api）。
class HighlightRulesScreen extends ConsumerStatefulWidget {
  const HighlightRulesScreen({super.key});

  @override
  ConsumerState<HighlightRulesScreen> createState() =>
      _HighlightRulesScreenState();
}

class _HighlightRulesScreenState extends ConsumerState<HighlightRulesScreen> {
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(bookApiProvider);
      final json = await api.highlightRuleList();
      final list = (jsonDecode(json) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        _rules = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 规则显示名（对标 Kotlin getDisplayName：name 为空时回退 pattern）
  String _displayName(Map<String, dynamic> rule) {
    final name = (rule['name'] as String?) ?? '';
    return name.isNotEmpty ? name : ((rule['pattern'] as String?) ?? '');
  }

  Future<void> _toggleEnabled(Map<String, dynamic> rule, bool enabled) async {
    final updated = Map<String, dynamic>.from(rule)..['isEnabled'] = enabled;
    final api = ref.read(bookApiProvider);
    await api.highlightRuleSave(ruleJson: jsonEncode(updated));
    await _load();
  }

  /// 删除确认（对标原版 alert(sure_del + displayName)）
  Future<void> _confirmDelete(Map<String, dynamic> rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('高亮规则'),
        content: Text('确定删除吗？\n${_displayName(rule)}'),
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
    final api = ref.read(bookApiProvider);
    await api.highlightRuleDelete(id: ((rule['id'] as num?) ?? 0).toInt());
    await _load();
  }

  Future<void> _edit(Map<String, dynamic>? rule) async {
    final saved = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        // 键盘弹起时 sheet 随动
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _HighlightRuleEditSheet(rule: rule),
      ),
    );
    if (saved == null) return;
    final api = ref.read(bookApiProvider);
    await api.highlightRuleSave(ruleJson: jsonEncode(saved));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('高亮规则'),
        actions: [
          // 对标 menu_add_highlight_rule
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增规则',
            onPressed: () => _edit(null),
          ),
        ],
      ),
      body: Builder(builder: (context) {
        if (_loading) return const LoadingIndicator(message: '加载高亮规则...');
        if (_error != null) {
          return Center(child: Text('加载失败: $_error'));
        }
        if (_rules.isEmpty) {
          return const EmptyState(
            icon: Icons.format_paint_outlined,
            title: '暂无高亮规则',
            subtitle: '点击右上角「+」新增自动高亮规则',
          );
        }
        // iOS grouped list：规则卡片 + hairline 分隔
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < _rules.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, indent: 16),
                    _buildRuleTile(context, _rules[i], cs),
                  ],
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildRuleTile(
      BuildContext context, Map<String, dynamic> rule, ColorScheme cs) {
    final enabled = (rule['isEnabled'] as bool?) ?? true;
    final pattern = (rule['pattern'] as String?) ?? '';
    final scope = (rule['scope'] as String?) ?? '';
    final isRegex = (rule['isRegex'] as bool?) ?? false;
    final name = (rule['name'] as String?) ?? '';
    return InkWell(
      onTap: () => _edit(rule),
      onLongPress: () => _confirmDelete(rule),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isNotEmpty ? name : pattern,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: enabled ? cs.onSurface : cs.onSurfaceVariant,
                        ),
                  ),
                  if (name.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        pattern,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        // 正则徽标
                        if (isRegex)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
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
                            style:
                                Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 启用开关（对标原版列表项 Switch）
            Switch(
              value: enabled,
              onChanged: (v) => _toggleEnabled(rule, v),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline,
                  size: 20, color: cs.onSurfaceVariant),
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              onPressed: () => _confirmDelete(rule),
            ),
          ],
        ),
      ),
    );
  }
}

/// 高亮规则编辑底部面板
///
/// 对标原版 HighlightRuleEditDialog 字段：
/// name / pattern / isRegex / applyToTitle / scope / style（颜色选择）。
class _HighlightRuleEditSheet extends StatefulWidget {
  final Map<String, dynamic>? rule;

  const _HighlightRuleEditSheet({this.rule});

  @override
  State<_HighlightRuleEditSheet> createState() =>
      _HighlightRuleEditSheetState();
}

class _HighlightRuleEditSheetState extends State<_HighlightRuleEditSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _patternCtrl;
  late final TextEditingController _scopeCtrl;
  late bool _isRegex;
  late bool _applyToTitle;
  // 高亮颜色（ARGB int，写入 style JSON 的 textColor 通道）
  late int _color;

  /// 预设高亮色（iOS 系统色，对标原版 HighlightColors 预设集）
  static const List<Color> _presetColors = [
    AppColors.iosYellowLight,
    AppColors.iosGreenLight,
    AppColors.iosTealLight,
    AppColors.iosBlueLight,
    AppColors.iosPurpleLight,
    AppColors.iosPinkLight,
    AppColors.iosRedLight,
    AppColors.iosOrangeLight,
  ];

  @override
  void initState() {
    super.initState();
    final rule = widget.rule ?? const <String, dynamic>{};
    _nameCtrl = TextEditingController(text: (rule['name'] as String?) ?? '');
    _patternCtrl =
        TextEditingController(text: (rule['pattern'] as String?) ?? '');
    _scopeCtrl = TextEditingController(text: (rule['scope'] as String?) ?? '');
    _isRegex = (rule['isRegex'] as bool?) ?? false;
    _applyToTitle = (rule['applyToTitle'] as bool?) ?? false;
    _color = _parseStyleColor((rule['style'] as String?) ?? '') ??
        AppColors.iosYellowLight.toARGB32();
  }

  /// 从 style JSON 解析 textColor（ARGB int）
  int? _parseStyleColor(String styleJson) {
    if (styleJson.isEmpty) return null;
    try {
      final obj = jsonDecode(styleJson) as Map<String, dynamic>;
      final v = obj['textColor'];
      if (v is num) return v.toInt();
    } catch (e) {
      // [审计修复 §4.1] style 非法时回退默认色，debugPrint 留痕便于排障 — Qoder
      debugPrint('高亮规则 style 解析失败，回退默认色: $e');
    }
    return null;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _scopeCtrl.dispose();
    super.dispose();
  }

  /// 组装保存 JSON（字段名与 Rust HighlightRule serde 契约一致）
  void _save() {
    final pattern = _patternCtrl.text.trim();
    if (pattern.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('匹配模式不能为空')),
      );
      return;
    }
    if (_isRegex) {
      try {
        RegExp(pattern);
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正则表达式无效，请检查')),
        );
        return;
      }
    }
    final rule = Map<String, dynamic>.from(widget.rule ?? const {});
    rule['name'] = _nameCtrl.text.trim();
    rule['pattern'] = pattern;
    rule['isRegex'] = _isRegex;
    rule['applyToTitle'] = _applyToTitle;
    final scope = _scopeCtrl.text.trim();
    rule['scope'] = scope.isEmpty ? null : scope;
    rule['isEnabled'] = (rule['isEnabled'] as bool?) ?? true;
    rule['style'] = jsonEncode({'textColor': _color});
    Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
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
            TextField(
              controller: _patternCtrl,
              decoration: const InputDecoration(
                labelText: '匹配模式 *',
                hintText: '要自动高亮的文本或正则表达式',
                filled: true,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用正则表达式'),
              value: _isRegex,
              onChanged: (v) => setState(() => _isRegex = v),
            ),
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
            const SizedBox(height: 16),
            Text('高亮颜色', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final color in _presetColors)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: GestureDetector(
                      onTap: () => setState(() => _color = color.toARGB32()),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _color == color.toARGB32()
                                ? cs.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // 预览（对标原版 tvStylePreview）
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Color(_color).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '高亮效果预览',
                style: TextStyle(color: Color(_color)),
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
