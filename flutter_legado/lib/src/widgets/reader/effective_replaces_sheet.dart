/// 本章生效替换规则 Sheet（批7c-1）
///
/// 对齐参考版 `EffectiveReplacesSheet.kt:35-168`：
/// - 生效规则 = 启用 && scopeContent && scope 匹配当前书，按 order 排序；
/// - 合成项置底：繁简转换（chineseConverterType 1/2）、重新分段
///   （readConfig.reSegment）；
/// - 行尾 X 禁用/关闭并重载正文；点规则进编辑页，合成项提示去阅读设置调整。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../screens/replace_rule_edit_screen.dart';
import '../../utils/error_message.dart';
import 'reader_action_helpers.dart';

/// 本章生效替换规则底部 Sheet
class EffectiveReplacesSheet extends ConsumerStatefulWidget {
  const EffectiveReplacesSheet({super.key});

  static Future<void> show(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.75,
        child: EffectiveReplacesSheet(),
      ),
    );
  }

  @override
  ConsumerState<EffectiveReplacesSheet> createState() =>
      _EffectiveReplacesSheetState();
}

class _EffectiveReplacesSheetState
    extends ConsumerState<EffectiveReplacesSheet> {
  List<ReplaceRule> _rules = const [];
  bool _loading = true;
  String? _error;
  int _convertType = 0;
  Book? _book;

  @override
  void initState() {
    super.initState();
    _book = ref.read(readerNotifierProvider).currentBook;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(bookApiProvider);
      final results = await Future.wait<Object>([
        api.getReplaceRules(),
        api.getChineseConvertType(),
      ]);
      if (!mounted) return;
      final rules = results[0] as List<ReplaceRule>;
      setState(() {
        _rules = [...rules]..sort(_compareRule);
        _convertType = results[1] as int;
        _book = ref.read(readerNotifierProvider).currentBook;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e);
        _loading = false;
      });
    }
  }

  int _compareRule(ReplaceRule a, ReplaceRule b) {
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
  }

  List<ReplaceRule> get _effectiveRules => _rules
      .where(
        (rule) =>
            rule.isEnabled &&
            rule.scopeContent &&
            replaceRuleScopeMatchesBook(rule.scope, _book?.name ?? ''),
      )
      .toList();

  bool get _reSegmentEnabled => _book?.readConfig?.reSegment ?? false;

  int get _entryCount =>
      _effectiveRules.length +
      (_convertType > 0 ? 1 : 0) +
      (_reSegmentEnabled ? 1 : 0);

  String get _convertLabel => _convertType == 2 ? '繁简转换（简转繁）' : '繁简转换（繁转简）';

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _reloadChapter() async {
    try {
      await ref.read(readerNotifierProvider.notifier).reloadChapterContent();
    } catch (e) {
      _snack('重新加载正文失败：${errorMessage(e)}');
    }
  }

  Future<void> _disableRule(ReplaceRule rule) async {
    try {
      await ref.read(bookApiProvider).setReplaceRuleEnabled(rule.id, false);
      if (!mounted) return;
      setState(() {
        _rules = [
          for (final item in _rules)
            item.id == rule.id ? item.copyWith(isEnabled: false) : item,
        ];
      });
      await _reloadChapter();
    } catch (e) {
      _snack('关闭替换规则失败：${errorMessage(e)}');
    }
  }

  Future<void> _disableConverter() async {
    try {
      await ref.read(bookApiProvider).setChineseConvertType(0);
      if (!mounted) return;
      setState(() => _convertType = 0);
      await _reloadChapter();
    } catch (e) {
      _snack('关闭繁简转换失败：${errorMessage(e)}');
    }
  }

  Future<void> _disableReSegment() async {
    await updateReaderBookConfig(
      context,
      ref,
      (config) => config.copyWith(reSegment: false),
    );
    if (!mounted) return;
    setState(() {
      _book = ref.read(readerNotifierProvider).currentBook;
    });
  }

  Future<void> _editRule(ReplaceRule rule) async {
    final saved = await ReplaceRuleEditScreen.open(context, rule: rule);
    if (saved != true || !mounted) return;
    await _load();
    await _reloadChapter();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('effective-replaces-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_fix_high_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('有效替换规则', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  if (!_loading && _error == null)
                    Text(
                      '本章生效 $_entryCount 条',
                      key: const ValueKey('effective-replaces-count'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (_book != null && _book!.name.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _book!.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(theme)),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final rules = _effectiveRules;
    if (rules.isEmpty && _convertType == 0 && !_reSegmentEnabled) {
      return Center(
        child: Text(
          '本章暂无生效替换规则',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        for (final rule in rules) _buildRuleRow(theme, rule),
        if (_convertType > 0) _buildSyntheticRow(theme, _convertLabel, true),
        if (_reSegmentEnabled) _buildSyntheticRow(theme, '重新分段', false),
      ],
    );
  }

  Widget _buildRuleRow(ThemeData theme, ReplaceRule rule) {
    final group = rule.group?.trim() ?? '';
    return Card(
      key: ValueKey('effective-replaces-rule-${rule.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _editRule(rule),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name.isEmpty ? '（未命名规则）' : rule.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${rule.pattern} → '
                      '${rule.replacement.isEmpty ? '∅' : rule.replacement}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (group.isNotEmpty)
                      Text(
                        '分组：$group',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.secondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('effective-replaces-remove-${rule.id}'),
                tooltip: '关闭',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => _disableRule(rule),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSyntheticRow(ThemeData theme, String label, bool converter) {
    return Card(
      key: ValueKey(
        converter
            ? 'effective-replaces-converter'
            : 'effective-replaces-resegment',
      ),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        dense: true,
        title: Text(label),
        onTap: () => _snack('请在阅读设置中调整'),
        trailing: IconButton(
          key: ValueKey(
            converter
                ? 'effective-replaces-remove-converter'
                : 'effective-replaces-remove-resegment',
          ),
          tooltip: '关闭',
          icon: const Icon(Icons.close, size: 20),
          onPressed: converter ? _disableConverter : _disableReSegment,
        ),
      ),
    );
  }
}
