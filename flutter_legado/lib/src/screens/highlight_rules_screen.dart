import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/md3_fast_scroller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/highlight_rules/highlight_rules_notifier.dart';
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
  @override
  void initState() {
    super.initState();
    // 首帧后加载，避免在 build 期间触发 notifier 状态写入
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(highlightRulesNotifierProvider.notifier).load();
    });
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
    _showErrorIfAny();
  }

  Future<void> _edit(HighlightRule? rule) async {
    final saved = await showModalBottomSheet<HighlightRule>(
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
    await ref.read(highlightRulesNotifierProvider.notifier).saveRule(saved);
    _showErrorIfAny();
  }

  /// notifier 状态中的错误提示到 UI（避免静默吞噬）
  void _showErrorIfAny() {
    final error = ref.read(highlightRulesNotifierProvider).error;
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('操作失败: $error')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final state = ref.watch(highlightRulesNotifierProvider);
    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('高亮规则'),
        actions: [
          // 对标 menu_add_highlight_rule
          IconButton(
            icon: const Icon(Symbols.add_rounded),
            tooltip: '新增规则',
            onPressed: () => _edit(null),
          ),
        ],
      ),
      body: Builder(builder: (context) {
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
        // iOS grouped list：规则卡片 + hairline 分隔
        // [UI_SYNC_REFACTOR R3] 规则列表快速滚动条
        return Md3FastScroller(
          controller: _fsController,
          child: ListView(
            controller: _fsController,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < state.rules.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: 16),
                      _buildRuleTile(context, state.rules[i], cs),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildRuleTile(
      BuildContext context, HighlightRule rule, ColorScheme cs) {
    final scope = rule.scope ?? '';
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
                        if (rule.isRegex)
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
            // [LAYOUT_PLAN P1] 开关行无 Chevron（等价 showChevron=false）；
            // 标题/副标题/元信息走 M3 Type Scale（titleMedium/bodySmall/labelSmall）
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
              icon: Icon(Symbols.delete_rounded,
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
  late bool _isRegex;
  late bool _applyToTitle;
  // 高亮颜色（ARGB int，写入 style JSON 的 textColor 通道）
  late int _color;

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
    _isRegex = rule?.isRegex ?? false;
    _applyToTitle = rule?.applyToTitle ?? false;
    // [审计修复 §4.1] style 非法时模型层回退 null，此处取默认色 — Qoder
    // [UI_MD3_ALIGNMENT_PLAN.md Batch B B7] 默认色延后至 build 由主题派生
    //（initState 无 context），0 表未初始化
    _color = rule?.styleTextColor ?? 0;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _scopeCtrl.dispose();
    super.dispose();
  }

  /// 组装保存模型（字段名与 Rust HighlightRule serde 契约一致）
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
    final scope = _scopeCtrl.text.trim();
    final base = widget.rule;
    final rule = HighlightRule(
      id: base?.id ?? 0,
      name: _nameCtrl.text.trim(),
      pattern: pattern,
      isRegex: _isRegex,
      applyToTitle: _applyToTitle,
      scope: scope.isEmpty ? null : scope,
      isEnabled: base?.isEnabled ?? true,
      style: jsonEncode({'textColor': _color}),
    );
    Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // [UI_MD3_ALIGNMENT_PLAN.md Batch B B7] 默认高亮色由当前主题派生
    final presetColors = _presetColors(cs);
    if (_color == 0) _color = presetColors.first.toARGB32();
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
            const SizedBox(height: 16),
            Text('高亮颜色', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final color in presetColors)
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
