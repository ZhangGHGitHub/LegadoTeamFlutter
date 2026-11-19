import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/md3_fast_scroller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/txt_toc_rules/txt_toc_rules_notifier.dart';
import '../services/source_share_passphrase.dart';
import '../widgets/empty_state.dart';
import '../widgets/export_file_sheet.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/passphrase_import.dart';
import '../utils/error_message.dart';

/// TXT 目录规则管理页面
///
/// 管理用于识别 TXT 小说章节标题的正则规则，
/// 支持添加 / 编辑 / 删除、启用开关以及在线测试匹配效果。
///
/// 规则经 [TxtTocRulesNotifier] 持久化到 Rust 配置库（BookApi.getConfig/setConfig），
/// 不再使用内存态；「在线测试」仅为本地正则预览，不参与实际数据流。
class TxtTocRulesScreen extends ConsumerStatefulWidget {
  const TxtTocRulesScreen({super.key});

  @override
  ConsumerState<TxtTocRulesScreen> createState() => _TxtTocRulesScreenState();
}

class _TxtTocRulesScreenState extends ConsumerState<TxtTocRulesScreen> {
  // [UI_SYNC_REFACTOR R3] 快速滚动条控制器
  final ScrollController _fsController = ScrollController();
  static const _sampleText = '''第一章 初入江湖
少年站在山门前，望着云雾缭绕的主峰。
第2章 拜师学艺
他恭恭敬敬地递上了拜师帖。
1、命运的转折
一封突如其来的书信改变了一切。
Chapter 4 The Beginning
It was a dark and stormy night.''';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(txtTocRulesNotifierProvider.notifier).load(),
    );
  }

  @override
  void dispose() {
    _fsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(txtTocRulesNotifierProvider);
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      // [台账 4-1 ①②⑦ | 2.0.274] 顶栏/入口重构（对齐参考 01_txt_toc_rule 截图）：
      // ① 大标题左对齐、动作钮上行独立——复用 LegadoTabRootHeaderSliver 大标题
      //    模式（滚动折叠为标准栏，_buildHeaderSliver）；
      // ② 新建入口改右下 + FAB（主题槽位着色，见 floatingActionButton）；
      // ⑦ 移除顶栏 ?/↺ 两直钮（原版 txt_toc_rule.xml 菜单仅 menu_add=always、
      //    帮助/导入默认=never 溢出，无独立顶栏钮），原版能力经 ⋮ 溢出菜单保留
      body: Md3FastScroller(
        controller: _fsController,
        child: CustomScrollView(
          controller: _fsController,
          slivers: [
            _buildHeaderSliver(context),
            if (state.isLoading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.rules.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Symbols.format_list_numbered_rounded,
                  title: AppStrings.txtTocRulesEmpty,
                  // [台账 4-1 ② | 2.0.274] 新建入口移至右下角 FAB
                  subtitle: AppStrings.txtTocRulesEmptyHint,
                ),
              )
            else
              // [UI_SYNC_REFACTOR R3] 规则列表（快速滚动条仍由 Md3FastScroller
              // 经 _fsController 驱动；上下留白 8dp 与原 ListView padding 一致）
              SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final rule = state.rules[index];
                      return _RuleTile(
                        rule: rule,
                        onToggle: (v) => ref
                            .read(txtTocRulesNotifierProvider.notifier)
                            .setEnabled(rule.id, v),
                        onEdit: () => _showRuleForm(context, rule: rule),
                        onDelete: () => _confirmDelete(rule),
                        onTest: () => _showTestDialog(rule),
                      );
                    },
                    childCount: state.rules.length,
                  ),
                ),
              ),
          ],
        ),
      ),
      // [台账 4-1 ② | 2.0.274] 新建入口：右下角 + FAB。着色走主题槽位
      // （app_theme floatingActionButtonTheme = primaryContainer 底 / primary
      // 前景，随调色板切换），不硬编码黄色；替代原顶栏圆形 + 钮
      floatingActionButton: FloatingActionButton(
        tooltip: AppStrings.addRuleAction,
        onPressed: () => _showRuleForm(context),
        child: const Icon(Symbols.add_rounded),
      ),
    );
  }

  /// [台账 4-1 ①⑦ | 2.0.274] 头部 sliver：可折叠大标题「TXT 目录规则」（左对齐，
  /// 展开 152dp，滚动折叠为标准栏）+ 返回钮（push 子页保留）+ ⋮ 溢出菜单
  /// （导入默认/帮助，对应原版菜单 never 项；?/↺ 直钮已移除）。
  Widget _buildHeaderSliver(BuildContext context) {
    return LegadoTabRootHeaderSliver(
      large: true,
      leading: IconButton(
        icon: const Icon(Symbols.arrow_back_rounded),
        tooltip: AppStrings.backLabel,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      title: Text(AppStrings.txtTocRulesLabel),
      actions: [
        PopupMenuButton<String>(
          tooltip: AppStrings.moreOptions,
          icon: const Icon(Symbols.more_vert_rounded),
          onSelected: _onMoreMenuSelected,
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'importDefault',
              child: Text(AppStrings.importDefaultAction),
            ),
            PopupMenuItem(
              value: 'passphrase',
              child: Text(AppStrings.importPassphraseAction),
            ),
            PopupMenuItem(
              value: 'export',
              child: Text(AppStrings.txtTocExportRules),
            ),
            PopupMenuItem(
              value: 'help',
              child: Text(AppStrings.helpLabel),
            ),
          ],
        ),
      ],
    );
  }

  /// [台账 4-1 ⑦ | 2.0.274] ⋮ 溢出菜单：保留原版 never 项能力
  /// （导入默认/帮助），批16e 增补「导出规则」。
  Future<void> _onMoreMenuSelected(String value) async {
    switch (value) {
      case 'help':
        showHelp(context, HelpAssets.txtTocRuleHelp);
      case 'importDefault':
        _importDefault();
      case 'passphrase':
        await importPassphraseFromClipboard(context);
      case 'export':
        _exportRules();
    }
  }

  /// 导出 TXT 目录规则（批16e：接入统一导出目标 Sheet）
  ///
  /// 对齐原版 `TxtTocRuleActivity.kt:301-308`（menu_export_selection →
  /// `GSON.toJson(adapter.selection)` → HandleFileContract.EXPORT）：
  /// 文件名 `exportTxtTocRule.json`、`application/json`，内容为规则数组。
  /// 本页暂无批量选择模式，菜单项导出全部规则。
  Future<void> _exportRules() async {
    final rules = ref.read(txtTocRulesNotifierProvider).rules;
    if (rules.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.txtTocNoRulesToExport)),
      );
      return;
    }
    final json = const JsonEncoder.withIndent('  ')
        .convert(rules.map((r) => r.toJson()).toList());
    final result = await showExportFileSheet(
      context,
      content: json,
      fileName: 'exportTxtTocRule.json',
      // 参考版 BaseRuleViewModel.uploadSelectedRules 固定上传该名
      uploadFileName: 'export_rules.json',
      subject: AppStrings.txtTocExportSubject,
      passphraseType: SourcePassphraseType.tocRule,
    );
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  Future<void> _importDefault() async {
    final n = await ref
        .read(txtTocRulesNotifierProvider.notifier)
        .importDefaultRules();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.txtTocImportedDefault(n))),
    );
  }

  void _confirmDelete(TxtTocRule rule) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppStrings.deleteRuleTitle),
        content: Text(
          AppStrings.txtTocConfirmDeleteNamed(
            rule.name.isEmpty ? AppStrings.unnamedTheme : rule.name,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(txtTocRulesNotifierProvider.notifier).deleteRule(rule.id);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(AppStrings.replaceRuleDeleted),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            child: Text(AppStrings.delete),
          ),
        ],
      ),
    );
  }

  void _showRuleForm(BuildContext context, {TxtTocRule? rule}) {
    final isEdit = rule != null;
    final nameCtrl = TextEditingController(text: rule?.name ?? '');
    final ruleCtrl = TextEditingController(text: rule?.rule ?? '');
    final replacementCtrl =
        TextEditingController(text: rule?.replacement ?? '');
    final exampleCtrl = TextEditingController(text: rule?.example ?? '');

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isEdit ? AppStrings.editRule : AppStrings.addRuleAction,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // [LAYOUT_PLAN P2] 输入框走 inputDecorationTheme（不显式 border）；
              // 字段分组间距 12dp
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.dictRuleName,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ruleCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.regexPattern,
                  hintText: r'^第\s*\d+\s*章',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: replacementCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.txtTocReplaceWith,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: exampleCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.txtTocExampleText,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (ruleCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(AppStrings.rulePatternRequired)),
                );
                return;
              }
              final updated = TxtTocRule(
                id: rule?.id ?? 0,
                name: nameCtrl.text.trim(),
                rule: ruleCtrl.text,
                replacement: replacementCtrl.text,
                example: exampleCtrl.text.isEmpty ? null : exampleCtrl.text,
                serialNumber: rule?.serialNumber ?? 0,
                enable: rule?.enable ?? true,
              );
              final notifier = ref.read(txtTocRulesNotifierProvider.notifier);
              if (isEdit) {
                notifier.updateRule(updated);
              } else {
                notifier.addRule(updated);
              }
              Navigator.pop(ctx);
            },
            child: Text(isEdit ? AppStrings.save : AppStrings.addAction),
          ),
        ],
      ),
    );
  }

  void _showTestDialog(TxtTocRule rule) {
    final textCtrl = TextEditingController(
      text: (rule.example != null && rule.example!.isNotEmpty)
          ? rule.example!
          : _sampleText,
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final result = _runTest(rule.rule, textCtrl.text);
          return AlertDialog(
            title: Text(AppStrings.txtTocTestTitle(rule.name)),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: textCtrl,
                    maxLines: 6,
                    // [LAYOUT_PLAN P2] 输入框走 inputDecorationTheme（不显式 border）
                    decoration: InputDecoration(
                      labelText: AppStrings.txtTocMatchText,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.txtTocMatchResults(result.matches.length),
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    width: double.maxFinite,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: result.error != null
                        ? Text(
                            AppStrings.txtTocRegexError('${result.error}'),
                            style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                          )
                        : result.matches.isEmpty
                            ? Text(
                                AppStrings.txtTocNoMatches,
                                style: TextStyle(
                                  color: Theme.of(ctx).colorScheme.outline,
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: result.matches.length,
                                itemBuilder: (_, i) => Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 2),
                                  child: Text(
                                    '${i + 1}. ${result.matches[i]}',
                                  ),
                                ),
                              ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.closeLabel),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 本地正则预览（仅供用户测试规则，不参与实际 TXT 解析数据流）
  _TestResult _runTest(String pattern, String text) {
    try {
      final regex = RegExp(pattern, multiLine: true);
      final matches = regex
          .allMatches(text)
          .map((m) => m.group(0)?.trim() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      return _TestResult(matches: matches);
    } catch (e) {
      return _TestResult(matches: const [], error: errorMessage(e));
    }
  }
}

/// 测试结果
class _TestResult {
  final List<String> matches;
  final String? error;

  const _TestResult({required this.matches, this.error});
}

/// 规则卡片
///
/// [台账 4-1 ③④⑤⑥ | 2.0.274] 对齐参考 01_txt_toc_rule 截图：
/// ⑤ 独立分体卡（圆角 14、卡间距 12，原连体紧凑卡 vertical 4）；
/// ③ 动作集图标化：铅笔=编辑、垃圾桶=删除（测试保留为次级文字钮）；
/// ④ 副标题显示匹配示例文本（rule.example），缺省时回退「正则:」+ 截断正则；
/// ⑥ 移除「已禁用」灰 chip（启用状态由开关表达，原版同语义）。
class _RuleTile extends StatelessWidget {
  final TxtTocRule rule;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  const _RuleTile({
    required this.rule,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onTest,
  });

  /// [台账 4-1 ④ | 2.0.274] 副标题：优先示例文本（对齐原版
  /// TxtTocRuleAdapter 副行取 example）；无示例时回退截断正则并加
  /// 「正则:」前缀标注（取舍说明：规则模型仅有 example/rule 两个文本源，
  /// 示例不可得时用正则截断兜底，避免副行空白）
  String _subtitle() {
    final example = rule.example;
    if (example != null && example.trim().isNotEmpty) {
      return example;
    }
    final r = rule.rule;
    return AppStrings.txtTocRegexPrefix(
      r.length > 40 ? '${r.substring(0, 40)}…' : r,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      // [台账 4-1 ⑤ | 2.0.274] 分体卡：圆角 14dp、卡间距 vertical 12dp
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name.isEmpty
                          ? AppStrings.unnamedParen
                          : rule.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        // [台账 4-1 ③] 图标化动作：铅笔编辑 / 垃圾桶删除 /
                        // 测试保留为次级（图标+文字小钮）
                        _iconAction(context, Symbols.edit_rounded,
                            AppStrings.edit, onEdit),
                        const SizedBox(width: 6),
                        _iconAction(context, Symbols.delete_outline_rounded,
                            AppStrings.delete, onDelete),
                        const SizedBox(width: 6),
                        _iconAction(context, Symbols.play_arrow_rounded,
                            AppStrings.testAction, onTest),
                      ],
                    ),
                  ],
                ),
              ),
              Switch(value: rule.enable, onChanged: onToggle),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconAction(BuildContext context, IconData icon, String label,
      VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
