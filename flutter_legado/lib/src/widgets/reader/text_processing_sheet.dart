/// 文字处理 Sheet（批7c-1）
///
/// 对齐参考版 `TextProcessingSheet.kt:108-221`：头部书名卡 + 两 Tab
/// 「替换净化」/「内容处理」；替换页含搜索、总开关、四筛选、拖动排序、
/// 行内启停、行尾菜单与整页管理入口；内容处理页只做空态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/replace_rule_edit_screen.dart';
import '../../utils/error_message.dart';
import 'reader_action_helpers.dart';

enum _ReplaceFilter { all, enabled, disabled, effective }

/// 文字处理底部 Sheet
class TextProcessingSheet extends ConsumerStatefulWidget {
  const TextProcessingSheet({super.key});

  static Future<void> show(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: const FractionallySizedBox(
          heightFactor: 0.85,
          child: TextProcessingSheet(),
        ),
      ),
    );
  }

  @override
  ConsumerState<TextProcessingSheet> createState() =>
      _TextProcessingSheetState();
}

class _TextProcessingSheetState extends ConsumerState<TextProcessingSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<ReplaceRule> _rules = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  _ReplaceFilter _filter = _ReplaceFilter.effective;
  bool _globalReplaceDefault = true;
  bool _busy = false;
  Book? _book;
  String? _inlineMessage;
  late final ReaderNotifier _readerNotifier;

  @override
  void initState() {
    super.initState();
    _readerNotifier = ref.read(readerNotifierProvider.notifier);
    _book = ref.read(readerNotifierProvider).currentBook;
    _init();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      _globalReplaceDefault = await ref.read(
        replaceEnableDefaultProvider.future,
      );
    } catch (_) {
      _globalReplaceDefault = true;
    }
    if (!mounted) return;
    await _loadRules();
  }

  Future<void> _loadRules() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rules = await ref.read(bookApiProvider).getReplaceRules();
      if (!mounted) return;
      setState(() {
        _rules = [...rules]..sort(_compareRule);
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

  List<ReplaceRule> get _filteredRules {
    final query = _query.trim().toLowerCase();
    return _rules.where((rule) {
      switch (_filter) {
        case _ReplaceFilter.enabled:
          if (!rule.isEnabled) return false;
        case _ReplaceFilter.disabled:
          if (rule.isEnabled) return false;
        case _ReplaceFilter.effective:
          if (!_isRuleEffective(rule)) return false;
        case _ReplaceFilter.all:
          break;
      }
      if (query.isEmpty) return true;
      return rule.name.toLowerCase().contains(query) ||
          rule.pattern.toLowerCase().contains(query) ||
          (rule.group ?? '').toLowerCase().contains(query);
    }).toList();
  }

  bool _isRuleEffective(ReplaceRule rule) {
    return isReplaceRuleEffectiveForBook(
      rule: rule,
      book: _book,
      globalReplaceDefault: _globalReplaceDefault,
    );
  }

  bool get _replaceEnabled =>
      effectiveReplaceRuleEnabled(_book, _globalReplaceDefault);

  void _showInline(String message) {
    if (!mounted) return;
    setState(() => _inlineMessage = message);
  }

  /// 成功操作后重载当前章；ReaderNotifier 在 initState 捕获，
  /// Sheet 已关闭时仍完成重载，mounted 只约束 UI 状态更新。
  Future<void> _reloadChapter() async {
    try {
      await _readerNotifier.reloadChapterContent();
    } catch (e) {
      _showInline('重新加载正文失败：${errorMessage(e)}');
    }
  }

  Future<void> _toggleMaster(bool value) async {
    if (_busy) return;
    _busy = true;
    try {
      final ok = await toggleReaderReplaceRule(
        context,
        ref,
        showMessages: false,
      );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _book = ref.read(readerNotifierProvider).currentBook;
          _inlineMessage = null;
        });
      } else {
        _showInline('切换替换净化失败，请重试');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _setRuleEnabled(ReplaceRule rule, bool enabled) async {
    try {
      await ref.read(bookApiProvider).setReplaceRuleEnabled(rule.id, enabled);
      if (mounted) {
        setState(() {
          _rules = [
            for (final item in _rules)
              item.id == rule.id ? item.copyWith(isEnabled: enabled) : item,
          ];
        });
      }
      await _reloadChapter();
    } catch (e) {
      _showInline('更新替换规则失败：${errorMessage(e)}');
    }
  }

  Future<void> _deleteRule(ReplaceRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除替换规则？'),
        content: Text(rule.name.isEmpty ? rule.pattern : rule.name),
        actions: [
          TextButton(
            key: const ValueKey('text-processing-delete-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('text-processing-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(bookApiProvider).deleteReplaceRule(rule.id);
      if (mounted) {
        setState(() {
          _rules = _rules.where((item) => item.id != rule.id).toList();
        });
      }
      await _reloadChapter();
    } catch (e) {
      _showInline('删除替换规则失败：${errorMessage(e)}');
    }
  }

  Future<void> _editRule(ReplaceRule rule) async {
    final saved = await ReplaceRuleEditScreen.open(context, rule: rule);
    if (saved != true || !mounted) return;
    await _loadRules();
    await _reloadChapter();
  }

  Future<void> _openManage() async {
    await Navigator.of(context).pushNamed(AppRoutes.replaceRules);
    if (!mounted) return;
    await _loadRules();
    await _reloadChapter();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Column(
        key: const ValueKey('text-processing-sheet'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _buildBookCard(theme),
          ),
          const TabBar(
            tabs: [
              Tab(text: '替换净化'),
              Tab(text: '内容处理'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildReplacePage(theme),
                _buildContentProcessPage(theme),
              ],
            ),
          ),
          if (_inlineMessage != null)
            Container(
              key: const ValueKey('text-processing-inline-message'),
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _inlineMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBookCard(ThemeData theme) {
    final book = _book;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.menu_book_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book?.name.isNotEmpty == true ? book!.name : '未打开书籍',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (book != null && book.author.isNotEmpty)
                  Text(
                    book.author,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplacePage(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _loadRules, child: const Text('重试')),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            key: const ValueKey('text-processing-search'),
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(
              hintText: '搜索规则',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        SwitchListTile(
          key: const ValueKey('text-processing-master-switch'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('使用替换净化'),
          subtitle: const Text('关闭后本章不应用任何替换规则'),
          value: _replaceEnabled,
          onChanged: _busy ? null : _toggleMaster,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final filter in _ReplaceFilter.values)
                ChoiceChip(
                  key: ValueKey('text-processing-filter-${filter.name}'),
                  label: Text(_filterLabel(filter)),
                  selected: _filter == filter,
                  onSelected: (_) => setState(() => _filter = filter),
                ),
            ],
          ),
        ),
        if (_filter == _ReplaceFilter.effective && !_replaceEnabled)
          Padding(
            key: const ValueKey('text-processing-master-off'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '本书替换净化已关闭',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(child: _buildRuleList()),
        const Divider(height: 1),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('text-processing-manage'),
            onPressed: _openManage,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('管理替换规则'),
          ),
        ),
      ],
    );
  }

  Widget _buildRuleList() {
    final rules = _filteredRules;
    if (rules.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty && _filter == _ReplaceFilter.all
              ? '暂无替换规则'
              : '没有符合条件的规则',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: rules.length,
      itemBuilder: (context, index) {
        final rule = rules[index];
        return _buildRuleTile(rule);
      },
    );
  }

  Widget _buildRuleTile(ReplaceRule rule) {
    final theme = Theme.of(context);
    final group = rule.group?.trim() ?? '';
    return Card(
      key: ValueKey('text-processing-rule-${rule.id}'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: () => _editRule(rule),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
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
                      '${rule.isRegex ? '正则' : '文本'}：${rule.pattern}'
                      ' → ${rule.replacement.isEmpty ? '∅' : rule.replacement}',
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
              Switch(
                key: ValueKey('text-processing-switch-${rule.id}'),
                value: rule.isEnabled,
                onChanged: (value) => _setRuleEnabled(rule, value),
              ),
              PopupMenuButton<String>(
                key: ValueKey('text-processing-menu-${rule.id}'),
                padding: EdgeInsets.zero,
                onSelected: (value) {
                  if (value == 'edit') {
                    _editRule(rule);
                  } else if (value == 'delete') {
                    _deleteRule(rule);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContentProcessPage(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome_outlined,
            size: 56,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('暂无 AI 处理记录', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            'AI 内容处理暂未支持',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _filterLabel(_ReplaceFilter filter) => switch (filter) {
    _ReplaceFilter.all => '全部',
    _ReplaceFilter.enabled => '已启用',
    _ReplaceFilter.disabled => '已停用',
    _ReplaceFilter.effective => '生效',
  };
}
