// 阅读器「TXT 目录规则」选择弹层（批43）
//
// 对齐原版 `TxtTocRuleDialog` / `TocActivity.onTocRegexDialogResult`：
// 列出规则库启用项 + 「默认规则」+「管理规则」入口，选中后写当前书
// `books.tocUrl`（原版格式 `rule + spaceChars + replacement`）并清空本地
// 章节缓存，再由调用方重载目录（Rust 侧 `setBookTocRule` 单列写）。
//
// 参考版入口：阅读器顶栏 `toc_rule`（仅本地 TXT）与目录页溢出菜单
// 「TXT 目录规则」。非 TXT 书不展示入口；误调用时提示不适用。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart'
    show Book, TocRuleReloadResult, TxtTocRule;
import '../../providers/providers.dart' show bookApiProvider;
import '../../providers/txt_toc_rules/txt_toc_rules_notifier.dart';
import '../../routes.dart';
import '../../utils/txt_toc_rule.dart';
import '../../utils/error_message.dart';

/// 弹层中「默认规则」的单选值（规则 id 用字符串，避免与默认值冲突）
const String _defaultRuleValue = '__default__';

/// 弹出「TXT 目录规则」选择弹层
///
/// [onApplied] 在单列写成功后调用（调用方负责重载目录），返回
/// [TocRuleReloadResult]：[TocRuleReloadResult.error] 非 null 表示重载失败
/// （提示失败，**不得提示成功**）；`usedCustomRule=false` 且本次选择的是
/// 具体规则时提示「规则未命中，已回退默认规则」（批43b P2-1，避免假成功）。
Future<void> showReaderTocRuleDialog(
  BuildContext context,
  WidgetRef ref, {
  required Book book,
  required Future<TocRuleReloadResult> Function(Book updated) onApplied,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!isLocalTxtBook(book)) {
    messenger.showSnackBar(const SnackBar(content: Text('TXT 目录规则仅适用于本地 TXT 书籍')));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _TxtTocRuleDialog(
      book: book,
      onApply: (ruleJson) async {
        Navigator.pop(dialogContext);
        try {
          final updated = await ref
              .read(bookApiProvider)
              .setBookTocRule(book.bookUrl, ruleJson);
          final result = await onApplied(updated);
          if (result.error != null) {
            messenger.showSnackBar(
              SnackBar(content: Text('应用目录规则后重载失败：${result.error}')),
            );
            return;
          }
          // 恢复默认（ruleJson == null）时 usedCustomRule=false 是预期结果；
          // 只有选了具体规则却回退默认，才提示「未命中」。
          if (ruleJson != null && !result.usedCustomRule) {
            messenger.showSnackBar(
              const SnackBar(content: Text('规则未命中，已回退默认规则')),
            );
            return;
          }
          messenger.showSnackBar(
            SnackBar(
              content: Text(ruleJson == null ? '已恢复默认目录规则' : '已应用目录规则'),
            ),
          );
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('设置目录规则失败: ${errorMessage(e)}')));
        }
      },
    ),
  );
}

class _TxtTocRuleDialog extends ConsumerStatefulWidget {
  final Book book;
  final Future<void> Function(String? ruleJson) onApply;

  const _TxtTocRuleDialog({required this.book, required this.onApply});

  @override
  ConsumerState<_TxtTocRuleDialog> createState() => _TxtTocRuleDialogState();
}

class _TxtTocRuleDialogState extends ConsumerState<_TxtTocRuleDialog> {
  /// 用户在当前弹层中主动选择的值；null 表示尚未操作（按书籍现状推导）
  String? _chosen;
  bool _userSelected = false;

  @override
  void initState() {
    super.initState();
    // 每次打开都重新拉取规则库，确保「管理规则」增删改后立即可见
    unawaited(Future.microtask(
      () => ref.read(txtTocRulesNotifierProvider.notifier).load(),
    ));
  }

  /// 按 `book.tocUrl` 推导当前选中值（对齐原版 `initSelectedName`）
  ///
  /// 不在 build 中落状态：规则列表异步加载/「管理规则」增删后，未操作用户
  /// 的勾选态会随最新列表自动重算。当前书使用规则库之外的正则时返回 null
  /// （不预选，需用户显式选「默认规则」或具体规则）。
  String? _derivedSelection(List<TxtTocRule> rules) {
    if (isDefaultTxtTocRule(widget.book.tocUrl)) return _defaultRuleValue;
    for (final rule in rules) {
      if (isTxtTocRuleSelected(widget.book.tocUrl, rule)) {
        return rule.id.toString();
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(txtTocRulesNotifierProvider);
    final rules = state.rules
        .where((r) => r.enable && r.rule.trim().isNotEmpty)
        .toList()
      ..sort((a, b) {
        final bySerial = a.serialNumber.compareTo(b.serialNumber);
        return bySerial != 0 ? bySerial : a.id.compareTo(b.id);
      });
    final selected =
        _userSelected ? _chosen : _derivedSelection(rules);

    final currentCustomRule =
        selected == null ? txtTocRuleRuleOf(widget.book.tocUrl) : null;

    // [批43b P3-6] 小屏自适应：规则列表高度不超过可用窗口的 45%，
    // 同时设上限 360；AlertDialog 开启 scrollable 兜底标题/说明/操作区，
    // 避免 360 固定高度在矮屏（如横屏/分屏）被系统裁切。
    final listMaxHeight =
        (MediaQuery.sizeOf(context).height * 0.45).clamp(160.0, 360.0);
    return AlertDialog(
      scrollable: true,
      title: const Text('TXT 目录规则'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: listMaxHeight),
                child: SingleChildScrollView(
                  child: RadioGroup<String?>(
                    groupValue: selected,
                    onChanged: (value) => setState(() {
                      _userSelected = true;
                      _chosen = value;
                    }),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<String?>(
                          value: _defaultRuleValue,
                          title: const Text('默认规则'),
                          subtitle: const Text('自动识别常见章节标题（推荐）'),
                        ),
                        for (final rule in rules)
                          RadioListTile<String?>(
                            value: rule.id.toString(),
                            title: Text(rule.name.isEmpty ? '未命名规则' : rule.name),
                            subtitle: Text(
                              rule.example?.isNotEmpty == true
                                  ? rule.example!
                                  : rule.rule,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (rules.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('规则库暂无启用的规则，可在「管理规则」中导入或新增'),
              ),
            if (currentCustomRule != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '当前书使用规则库之外的规则：$currentCustomRule',
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '规则加载失败：${state.error}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Navigator.pushNamed(context, AppRoutes.txtTocRules);
            if (!mounted) return;
            await ref.read(txtTocRulesNotifierProvider.notifier).load();
          },
          child: const Text('管理规则'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          // 当前书是规则库外规则时需先选「默认规则」或具体规则
          onPressed: selected == null ? null : () => _apply(rules, selected),
          child: const Text('确定'),
        ),
      ],
    );
  }

  void _apply(List<TxtTocRule> rules, String selected) {
    if (selected == _defaultRuleValue) {
      widget.onApply(null);
      return;
    }
    TxtTocRule? rule;
    for (final candidate in rules) {
      if (candidate.id.toString() == selected) {
        rule = candidate;
        break;
      }
    }
    if (rule == null) return;
    widget.onApply(encodeTxtTocRuleJson(rule));
  }
}
