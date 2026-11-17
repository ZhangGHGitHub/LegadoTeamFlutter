import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/dict/dict_notifier.dart';
import '../routes.dart';
import '../utils/error_message.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';

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
          SnackBar(content: Text(AppStrings.cannotOpenOnlineDict)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(dictNotifierProvider);
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: Text(AppStrings.dictLookupTitle),
        actions: [
          IconButton(
            icon: const Icon(Symbols.help_rounded),
            tooltip: AppStrings.helpLabel,
            onPressed: () => showHelp(context, HelpAssets.dictRuleHelp),
          ),
          IconButton(
            icon: const Icon(Symbols.rule_folder_rounded),
            tooltip: AppStrings.dictRulesManageTitle,
            onPressed: _showRuleManager,
          ),
          // [C2 批2 | full-stack-engineer + UI] 字典规则管理页入口
          // （对齐原版 DictRuleActivity；既有「词典规则管理」弹窗保留）
          IconButton(
            icon: const Icon(Symbols.manage_search_rounded),
            tooltip: AppStrings.ruleManagement,
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.dictRule),
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
      // [LAYOUT_PLAN P2] 页面水平边距 16dp；搜索行纵向 12dp
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
              // [LAYOUT_PLAN P2] 输入框走 inputDecorationTheme（不显式 border/radius）
              decoration: InputDecoration(
                prefixIcon: const Icon(Symbols.search_rounded),
                hintText: AppStrings.dictSearchHint,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _search,
            child: Text(AppStrings.queryAction),
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
      // [LAYOUT_PLAN P2] 页面边距统一 16dp（全局标尺）
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
          Icon(Symbols.menu_book_rounded, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(AppStrings.dictStartHint, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text(
            AppStrings.dictOnlineFallbackHint,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme, DictEntry entry) {
    return Card(
      // [LAYOUT_PLAN P2] 分组卡圆角 16dp；卡内统一 16dp
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
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
                  // [LAYOUT_PLAN P2] 状态色走 tonal（primaryContainer/onPrimaryContainer）
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    AppStrings.localDictionary,
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
                    Icon(Symbols.circle_rounded, size: 6,
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
      // [LAYOUT_PLAN P2] 分组卡圆角 16dp；卡内统一 16dp
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(Symbols.search_off_rounded, size: 40,
                color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(
              AppStrings.dictWordNotFound(word),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              AppStrings.dictUseOnlineBelow,
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
        Text(AppStrings.onlineDictionary, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (state.rules.isEmpty)
          Text(
            AppStrings.noDictRulesTapManage,
            style: theme.textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: state.rules
                .map((rule) => ActionChip(
                      avatar: const Icon(Symbols.open_in_new_rounded, size: 16),
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
            title: Text(AppStrings.dictRulesManageTitle),
            content: SizedBox(
              width: double.maxFinite,
              child: rules.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(AppStrings.noRulesTapAddBelow),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: rules.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final rule = rules[index];
                        return ListTile(
                          dense: true,
                          // [LAYOUT_PLAN P2] 组内行 vertical12/horizontal8
                          contentPadding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 8),
                          title: Text(rule.name),
                          subtitle: Text(
                            rule.urlRule,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Symbols.delete_rounded, size: 20),
                            onPressed: () async {
                              // B7：删除走 §2.45 FFI（按行 id），失败提示
                              // 提示器在 await 前取好，避免跨异步间隙用 context
                              final messenger =
                                  ScaffoldMessenger.of(this.context);
                              try {
                                await ref
                                    .read(dictNotifierProvider.notifier)
                                    .deleteRule(index);
                              } catch (e) {
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      AppStrings.deleteFailed(
                                        errorMessage(e),
                                      ),
                                    ),
                                  ),
                                );
                              }
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
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(AppStrings.defaultDictRulesImported(n)),
                      ),
                    );
                  }
                },
                child: Text(AppStrings.importDefaultAction),
              ),
              TextButton(
                onPressed: () =>
                    _showRuleEditor(ctx, onSaved: setDialogState),
                child: Text(AppStrings.addRuleAction),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(AppStrings.doneLabel),
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
        title: Text(AppStrings.addDictionaryRule),
        content: Column(
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
              controller: urlCtrl,
              decoration: InputDecoration(
                labelText: AppStrings.dictRuleQueryUrl,
                hintText: AppStrings.dictWordPlaceholderHint,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(editCtx).pop(),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              // B7：保存走 §2.45 FFI（写 dictRules 表，查询立即可见）；
              // 名称重复由 Rust UNIQUE 约束报错，此处提示而不是静默关闭
              try {
                await ref
                    .read(dictNotifierProvider.notifier)
                    .addRule(DictRule(name: name, urlRule: url));
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppStrings.saveFailedWith(errorMessage(e))),
                    ),
                  );
                }
                return;
              }
              onSaved(() {});
              if (editCtx.mounted) Navigator.of(editCtx).pop();
            },
            child: Text(AppStrings.save),
          ),
        ],
      ),
    );
  }
}
