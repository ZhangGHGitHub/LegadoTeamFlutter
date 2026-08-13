import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../providers/dict/dict_notifier.dart';

/// 字典查询页面
///
/// 优先查询内置本地词典，未命中时可通过在线词典规则跳转查询。
/// 在线词典规则经 [DictNotifier] 持久化到 Rust 配置库（BookApi.getConfig/setConfig），
/// 不再使用 SharedPreferences；词典查询已接通 Rust FFI（BookApi.dictLookup，
/// 见 dict_notifier.dart）。[审计修复 §4.5] 清理陈旧注释 — Qoder
class DictScreen extends ConsumerStatefulWidget {
  const DictScreen({super.key});

  @override
  ConsumerState<DictScreen> createState() => _DictScreenState();
}

class _DictScreenState extends ConsumerState<DictScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(dictNotifierProvider.notifier).loadRules(),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _search() {
    ref.read(dictNotifierProvider.notifier).lookup(_searchController.text);
  }

  Future<void> _launchOnline(DictRule rule) async {
    final word =
        ref.read(dictNotifierProvider).queriedWord ?? _searchController.text.trim();
    if (word.isEmpty) return;
    final uri = Uri.tryParse(rule.buildUrl(word));
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开在线词典')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(dictNotifierProvider);
    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('字典查询'),
        actions: [
          IconButton(
            icon: const Icon(Icons.rule_folder_outlined),
            tooltip: '词典规则管理',
            onPressed: _showRuleManager,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(theme),
          const Divider(height: 1),
          Expanded(child: _buildBody(theme, state)),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '输入单词查询释义',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _search,
            child: const Text('查询'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme, DictState state) {
    if (state.queriedWord == null) {
      return _buildEmptyHint(theme);
    }
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final entry = state.result;
    final notFound = entry == null || entry.definitions.isEmpty;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!notFound)
          _buildResultCard(theme, entry)
        else
          _buildNotFound(theme, state.queriedWord!),
        const SizedBox(height: 20),
        _buildOnlineSection(theme, state),
      ],
    );
  }

  Widget _buildEmptyHint(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('输入单词开始查询', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text(
            '未收录的词可跳转在线词典',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme, DictEntry entry) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  entry.word,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    entry.phonetic,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '本地词典',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...entry.definitions.map(
              (d) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.circle, size: 6,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(d, style: theme.textTheme.bodyLarge)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotFound(ThemeData theme, String word) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(Icons.search_off, size: 40,
                color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(
              '本地词典未收录「$word」',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '可使用下方在线词典查询',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnlineSection(ThemeData theme, DictState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('在线词典', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (state.rules.isEmpty)
          Text('暂无词典规则，点击右上角管理添加',
              style: theme.textTheme.bodySmall)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: state.rules
                .map((rule) => ActionChip(
                      avatar: const Icon(Icons.open_in_new, size: 16),
                      label: Text(rule.name),
                      onPressed: () => _launchOnline(rule),
                    ))
                .toList(),
          ),
      ],
    );
  }

  // ========== 词典规则管理 ==========

  void _showRuleManager() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final rules = ref.read(dictNotifierProvider).rules;
          return AlertDialog(
            title: const Text('词典规则管理'),
            content: SizedBox(
              width: double.maxFinite,
              child: rules.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('暂无规则，点击下方按钮添加'),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: rules.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final rule = rules[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(rule.name),
                          subtitle: Text(
                            rule.urlRule,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () async {
                              await ref
                                  .read(dictNotifierProvider.notifier)
                                  .deleteRule(index);
                              setDialogState(() {});
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final n = await ref
                      .read(dictNotifierProvider.notifier)
                      .importDefaultRules();
                  setDialogState(() {});
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已导入 $n 条原版默认词典规则')),
                    );
                  }
                },
                child: const Text('导入默认'),
              ),
              TextButton(
                onPressed: () =>
                    _showRuleEditor(ctx, onSaved: setDialogState),
                child: const Text('添加规则'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showRuleEditor(BuildContext ctx, {required StateSetter onSaved}) {
    final nameCtrl = TextEditingController();
    final urlCtrl =
        TextEditingController(text: 'https://example.com/dict?q={{key}}');
    showDialog(
      context: ctx,
      builder: (editCtx) => AlertDialog(
        title: const Text('添加词典规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: '规则名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: '查询地址',
                hintText: '使用 {{key}} 作为单词占位符',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(editCtx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              await ref
                  .read(dictNotifierProvider.notifier)
                  .addRule(DictRule(name: name, urlRule: url));
              onSaved(() {});
              if (editCtx.mounted) Navigator.of(editCtx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
