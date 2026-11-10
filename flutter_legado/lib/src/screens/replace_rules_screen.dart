import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/md3_fast_scroller.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import '../services/bridge_http.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/replace_rule/replace_rule_notifier.dart';
import '../routes.dart';
import '../services/source_share_passphrase.dart';
import '../widgets/export_file_sheet.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/passphrase_import.dart';
import '../widgets/replace_rule_group_manage_dialog.dart';
import 'replace_rule_edit_screen.dart';
import 'replace_rule_import_confirm_screen.dart';

/// 替换规则管理页面
class ReplaceRulesScreen extends ConsumerStatefulWidget {
  // [UI-fix v2.0.2 | 2026-08-06] 路由参数：新规则 pattern 预填（阅读器
  // 长按选中文本传入，对标原版 ReplaceEditActivity 预填） — Qoder
  final String? initialPattern;

  const ReplaceRulesScreen({super.key, this.initialPattern});

  @override
  ConsumerState<ReplaceRulesScreen> createState() => _ReplaceRulesScreenState();
}

class _ReplaceRulesScreenState extends ConsumerState<ReplaceRulesScreen> {
  final _searchCtrl = TextEditingController();
  String _filter = '';

  // [UI-fix v2.0.2 | 2026-08-06] 分组筛选（对标原版 menu_group：
  // 全部/启用/禁用/无分组/分组:x） — Qoder
  String? _groupFilter;

  // [UI-fix v2.0.2 | 2026-08-06] 批量模式（对标原版 replace_rule_sel.xml：
  // 启用选中/禁用选中/置顶/置底/导出选中） — Qoder
  bool _batchMode = false;
  // [UI_SYNC_REFACTOR R3] 快速滚动条控制器
  final ScrollController _ruleListController = ScrollController();
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(replaceRuleNotifierProvider.notifier).load();
      // 路由预填 pattern：首帧后直接打开整页编辑器（pattern 已预填，
      // 对标原版 startIntent pattern 预填；[A3 形态对齐 | full-stack-engineer + UI]）
      final pattern = widget.initialPattern;
      if (mounted && pattern != null && pattern.isNotEmpty) {
        ReplaceRuleEditScreen.open(context, prefillPattern: pattern);
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(replaceRuleNotifierProvider);
    final notifier = ref.read(replaceRuleNotifierProvider.notifier);
    final filtered = _applyFilters(state.rules);
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      // 对齐原版 activity_replace_rule.xml：TitleBar 内嵌 view_search 搜索框
      topBar: _batchMode
          ? _buildBatchAppBar()
          : LegadoAppBar(
              titleSpacing: 0,
              title: SizedBox(
                height: 36,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _filter = v.trim()),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: '搜索规则',
                    hintStyle: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onPrimary.withValues(alpha: 0.6),
                    ),
                    prefixIcon: Icon(
                      Symbols.search_rounded,
                      size: 20,
                      color: Theme.of(
                        context,
                      ).colorScheme.onPrimary.withValues(alpha: 0.8),
                    ),
                    filled: true,
                    // [深色主题 Batch A-2] 白色 0.2 填充 → surfaceContainerHighest：
                    // 亮/暗两态下均为「AppBar surface 之上的一级 tonal 抬升」，
                    // 消除亮态近不可见、暗态呈灰白填充的双态不一致
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    // [B3] 搜索胶囊：无描边无底线、聚焦零变化
                    // （显式声明防主题底部指示线渗入）
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              actions: [
                // [UI-fix v2.0.2 | 2026-08-06] 分组筛选入口（对标原版 menu_group）— Qoder
                PopupMenuButton<String?>(
                  tooltip: '分组筛选',
                  icon: Icon(
                    _groupFilter == null
                        ? Symbols.filter_list_rounded
                        : Symbols.filter_alt_rounded,
                  ),
                  onSelected: (v) => setState(() => _groupFilter = v),
                  itemBuilder: (_) => [
                    const PopupMenuItem<String?>(
                      value: null,
                      child: Text('全部'),
                    ),
                    const PopupMenuItem<String?>(
                      value: '__enabled__',
                      child: Text('启用'),
                    ),
                    const PopupMenuItem<String?>(
                      value: '__disabled__',
                      child: Text('禁用'),
                    ),
                    const PopupMenuItem<String?>(
                      value: '__null__',
                      child: Text('无分组'),
                    ),
                    for (final g in _collectGroups(state.rules))
                      PopupMenuItem<String?>(value: g, child: Text('分组：$g')),
                  ],
                ),
                // P2-12：分组管理（对标原版 menu_group_manage → GroupManageDialog）
                IconButton(
                  icon: const Icon(Symbols.folder_rounded),
                  tooltip: '分组管理',
                  onPressed: () => _showGroupManage(context, state.rules),
                ),
                // [UI-fix v2.0.2 | 2026-08-06] 导入入口接 ReplaceRuleImportConfirmScreen
                // （对标原版 ReplaceRuleActivity menu_import：本地/网络/二维码均已接通） — Qoder
                PopupMenuButton<String>(
                  tooltip: '导入',
                  icon: const Icon(Symbols.file_download_rounded),
                  onSelected: _handleImportMenu,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'local', child: Text('本地导入')),
                    PopupMenuItem(value: 'online', child: Text('网络导入')),
                    PopupMenuItem(value: 'qrcode', child: Text('二维码导入')),
                    PopupMenuItem(value: 'passphrase', child: Text('口令导入')),
                  ],
                ),
                // [UI-fix v2.0.2 | 2026-08-06] 批量模式入口 — Qoder
                IconButton(
                  icon: const Icon(Symbols.checklist_rounded),
                  tooltip: '批量操作',
                  onPressed: () => setState(() => _batchMode = true),
                ),
                IconButton(
                  icon: const Icon(Symbols.help_rounded),
                  tooltip: '帮助',
                  onPressed: () =>
                      showHelp(context, HelpAssets.replaceRuleHelp),
                ),
                // [A3 形态对齐 | full-stack-engineer + UI] 新增入口跳整页编辑器
                IconButton(
                  icon: const Icon(Symbols.add_rounded),
                  onPressed: () => ReplaceRuleEditScreen.open(context),
                ),
              ],
            ),
      body: Builder(
        builder: (context) {
          if (state.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.error != null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.error_rounded,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(state.error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => notifier.load(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          if (state.rules.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.find_replace_rounded,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text('暂无替换规则', style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  Text(
                    '点击右上角 + 添加规则',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          }
          if (filtered.isEmpty) {
            return Center(
              child: Text(
                '未找到匹配「$_filter」的规则',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          return _buildRuleList(context, notifier, filtered);
        },
      ),
    );
  }

  Widget _buildRuleList(
    BuildContext context,
    ReplaceRuleNotifier provider,
    List<ReplaceRule> rules,
  ) {
    // [UI-fix v2.0.2 | 2026-08-06] 批量模式下禁用拖拽排序，行点击切换选中 — Qoder
    if (_batchMode) {
      // [UI_SYNC_REFACTOR R3] 快速滚动条（批量模式长列表）
      return Md3FastScroller(
        controller: _ruleListController,
        child: ListView.builder(
          controller: _ruleListController,
          // [LAYOUT_PLAN P2] 列表纵向留白 8dp，横向由卡片 margin 统一 16dp
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: rules.length,
          itemBuilder: (context, index) {
            final rule = rules[index];
            return _ReplaceRuleTile(
              key: ValueKey(rule.id),
              rule: rule,
              index: index,
              batchMode: true,
              selected: _selected.contains(rule.id),
              onSelect: () => _toggleSelect(rule.id),
              onToggle: (enabled) => provider.setEnabled(rule.id, enabled),
              onEdit: () => _toggleSelect(rule.id),
              onDelete: () => _confirmDelete(context, provider, rule),
            );
          },
        ),
      );
    }

    // [批12 | 2026-11-10] 筛选/搜索/分组子集态不可拖拽：子集无法安全全量
    // 重排（会打乱未展示规则），Rust 侧也会以「缺失 id」拒绝子集提交。
    final subsetMode = _filter.isNotEmpty || _groupFilter != null;
    if (subsetMode) {
      return Column(
        children: [
          _buildSubsetReorderHint(context),
          Expanded(
            child: ListView.builder(
              controller: _ruleListController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: rules.length,
              itemBuilder: (context, index) {
                final rule = rules[index];
                return _ReplaceRuleTile(
                  key: ValueKey(rule.id),
                  rule: rule,
                  index: index,
                  showDragHandle: false,
                  onToggle: (enabled) => provider.setEnabled(rule.id, enabled),
                  onEdit: () => ReplaceRuleEditScreen.open(context, rule: rule),
                  onDelete: () => _confirmDelete(context, provider, rule),
                  onEnterBatch: () => _enterBatch(rule.id),
                );
              },
            ),
          ),
        ],
      );
    }

    return ReorderableListView.builder(
      // [LAYOUT_PLAN P2] 列表纵向留白 8dp，横向由卡片 margin 统一 16dp
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rules.length,
      // [批12] 一次全量重排落库（onReorderItem 的 newIndex 已按移除项调整）
      onReorderItem: (oldIndex, newIndex) async {
        final ok = await provider.reorder(oldIndex, newIndex);
        if (!mounted || ok) return;
        _showSortFailure();
      },
      itemBuilder: (context, index) {
        final rule = rules[index];
        return _ReplaceRuleTile(
          key: ValueKey(rule.id),
          rule: rule,
          index: index,
          onToggle: (enabled) => provider.setEnabled(rule.id, enabled),
          // [A3 形态对齐 | full-stack-engineer + UI] 列表行编辑跳整页编辑器
          onEdit: () => ReplaceRuleEditScreen.open(context, rule: rule),
          onDelete: () => _confirmDelete(context, provider, rule),
          onEnterBatch: () => _enterBatch(rule.id),
        );
      },
    );
  }

  /// [批12] 子集筛选态拖拽禁用说明
  Widget _buildSubsetReorderHint(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Icon(
            Symbols.info_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '筛选/搜索状态下暂不支持拖拽排序',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// [批12] 排序落库失败提示
  ///
  /// 文案不承诺「已恢复原顺序」：`load()` 回滚本身可能失败（DB 不可用），
  /// 此时 state.error 会驱动错误态，SnackBar 只陈述保存失败。
  void _showSortFailure() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('排序保存失败')));
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 分组筛选 — Qoder =====

  /// P2-12：分组管理弹窗（对标原版 GroupManageDialog）
  Future<void> _showGroupManage(
    BuildContext context,
    List<ReplaceRule> rules,
  ) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => ReplaceRuleGroupManageDialog(rules: rules),
    );
    if (changed == true && mounted) {
      await ref.read(replaceRuleNotifierProvider.notifier).load();
    }
  }

  /// 收集所有分组名（规则的 group 字段可含逗号分隔多分组）
  List<String> _collectGroups(List<ReplaceRule> rules) {
    final groups = <String>{};
    for (final r in rules) {
      final g = r.group;
      if (g == null || g.trim().isEmpty) continue;
      groups.addAll(
        g.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    }
    return groups.toList()..sort();
  }

  /// 分组筛选 + 搜索词叠加过滤（对标原版分组下拉 + view_search）
  List<ReplaceRule> _applyFilters(List<ReplaceRule> rules) {
    Iterable<ReplaceRule> result = rules;
    switch (_groupFilter) {
      case null:
        break;
      case '__enabled__':
        result = result.where((r) => r.isEnabled);
      case '__disabled__':
        result = result.where((r) => !r.isEnabled);
      case '__null__':
        result = result.where(
          (r) => r.group == null || r.group!.trim().isEmpty,
        );
      default:
        final g = _groupFilter!;
        result = result.where(
          (r) => r.group?.split(',').map((e) => e.trim()).contains(g) ?? false,
        );
    }
    if (_filter.isNotEmpty) {
      result = result.where(
        (r) =>
            r.name.contains(_filter) ||
            r.pattern.contains(_filter) ||
            (r.group?.contains(_filter) ?? false),
      );
    }
    return result.toList();
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 批量操作（对标 replace_rule_sel.xml）— Qoder =====

  /// 长按进入批量模式并选中该项（对标原版列表长按进入选择态）
  void _enterBatch(int id) {
    setState(() {
      _batchMode = true;
      _selected.add(id);
    });
  }

  void _toggleSelect(int id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _exitBatch() {
    setState(() {
      _batchMode = false;
      _selected.clear();
    });
  }

  /// 批量模式顶栏（对标原版 SelectActionBar：关闭 + 已选计数 + 全选）
  PreferredSizeWidget _buildBatchAppBar() {
    return LegadoAppBar(
      leading: IconButton(
        icon: const Icon(Symbols.close_rounded),
        tooltip: '退出批量模式',
        onPressed: _exitBatch,
      ),
      title: Text('已选择 ${_selected.length} 项'),
      actions: [
        IconButton(
          icon: const Icon(Symbols.select_all_rounded),
          tooltip: '全选',
          onPressed: () {
            final state = ref.read(replaceRuleNotifierProvider);
            setState(() {
              _selected.addAll(_applyFilters(state.rules).map((r) => r.id));
            });
          },
        ),
        PopupMenuButton<String>(
          tooltip: '批量操作',
          onSelected: _handleBatchAction,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'enable', child: Text('启用选中')),
            PopupMenuItem(value: 'disable', child: Text('禁用选中')),
            PopupMenuItem(value: 'top', child: Text('置顶')),
            PopupMenuItem(value: 'bottom', child: Text('置底')),
            PopupMenuItem(value: 'export', child: Text('导出选中')),
          ],
        ),
      ],
    );
  }

  /// 批量操作分发（5 项：启用选中/禁用选中/置顶/置底/导出选中）
  Future<void> _handleBatchAction(String action) async {
    if (_selected.isEmpty) return;
    final notifier = ref.read(replaceRuleNotifierProvider.notifier);
    final ids = _selected.toList();
    switch (action) {
      case 'enable':
      case 'disable':
        for (final id in ids) {
          await notifier.setEnabled(id, action == 'enable');
        }
        _exitBatch();
      case 'top':
        // [批12] 重排数组后一次全量落库；失败已回滚并提示
        final topOk = await notifier.moveToTop(ids);
        if (!mounted) return;
        if (!topOk) _showSortFailure();
        _exitBatch();
      case 'bottom':
        final bottomOk = await notifier.moveToBottom(ids);
        if (!mounted) return;
        if (!bottomOk) _showSortFailure();
        _exitBatch();
      case 'export':
        await _exportSelected(ids);
    }
  }

  /// 导出选中规则（批16e：接入统一导出目标 Sheet）
  ///
  /// 对齐原版 `ReplaceRuleActivity.kt:297-304`（menu_export_selection →
  /// `GSON.toJson(ReplacePreviewConfig.withSamples(selection))` →
  /// HandleFileContract.EXPORT，文件名 `exportReplaceRule.json`，
  /// `application/json`）。
  ///
  /// **已知差异（批16e 回修 P2-3，登记不阻塞）**：原版 `withSamples` 会把
  /// 编辑页临时保存的 `previewText` 一并写入导出 JSON；本项目未持久化该
  /// 样本（仅编辑页复制规则时临时携带），因此导出内容不含 `previewText`。
  /// 除此之外字段与规则数组形态一致，但**不声称与原版 1:1**；如需样本
  /// 随导出携带，须先补 previewText 的持久化存储（另立任务）。
  Future<void> _exportSelected(List<int> ids) async {
    final rules = ref
        .read(replaceRuleNotifierProvider)
        .rules
        .where((r) => ids.contains(r.id))
        .toList();
    if (rules.isEmpty) return;
    final json = const JsonEncoder.withIndent(
      '  ',
    ).convert(rules.map((r) => r.toJson()).toList());
    final result = await showExportFileSheet(
      context,
      content: json,
      fileName: 'exportReplaceRule.json',
      // 参考版 BaseRuleViewModel.uploadSelectedRules 固定上传该名
      uploadFileName: 'export_rules.json',
      subject: '导出替换规则',
      passphraseType: SourcePassphraseType.replaceRule,
    );
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
    _exitBatch();
  }

  /// [UI-fix v2.0.1 | 2026-08-06] 导入菜单分发
  /// [UI-fix v2.0.2 | 2026-08-06] 网络/二维码导入接通（复用导入确认页） — Qoder
  Future<void> _handleImportMenu(String value) async {
    switch (value) {
      case 'local':
        _importFromFile();
      case 'online':
        _showImportUrlDialog();
      case 'qrcode':
        _importFromQrCode();
      case 'passphrase':
        await importPassphraseFromClipboard(context);
    }
  }

  /// 网络导入弹窗（对标原版 showImportDialog：URL 输入 + 历史记录）
  Future<void> _showImportUrlDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs
        .getString('replaceRuleImportUrls')
        ?.split(',')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (!mounted) return;
    final url = await showDialog<String>(
      context: context,
      builder: (_) => _ImportUrlDialog(history: history ?? []),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    final trimmed = url.trim();
    // 保存历史记录（逗号分隔，最多 10 条，对标原版 InputDialog history）
    final updated = [
      trimmed,
      ...(history ?? []).where((e) => e != trimmed),
    ].take(10).toList();
    await prefs.setString('replaceRuleImportUrls', updated.join(','));
    if (!mounted) return;
    await _fetchFromUrl(trimmed);
  }

  /// 从 URL 拉取规则文本后进入导入确认页
  Future<void> _fetchFromUrl(String url) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final api = ref.read(bookApiProvider);
      final response = await bridgeHttpGet(
        api,
        url,
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭加载指示
      if (!response.isSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取替换规则失败：HTTP ${response.statusCode}')),
        );
        return;
      }
      await _parseAndConfirm(response.body);
    } catch (e) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取替换规则失败：$e')));
      }
    }
  }

  /// 二维码导入（对标原版 menu_import_qr）：
  /// HTTP URL → 远程拉取；JSON → 直接解析
  Future<void> _importFromQrCode() async {
    // [fix Task#24 | 2026-08-08] 去掉 <String> 泛型，避免 routes 表
    // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
    final raw = await Navigator.of(context).pushNamed(AppRoutes.qrcode);
    final content = raw is String ? raw : null;
    if (!mounted) return;
    if (content == null || content.trim().isEmpty) return;
    final trimmed = content.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      await _fetchFromUrl(trimmed);
      return;
    }
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      await _parseAndConfirm(trimmed);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('扫码内容不是可识别的替换规则数据')));
  }

  /// 本地文件导入（对标原版 menu_import_local：任选文件，解析层容错）
  ///
  /// 注：与书源/RSS 导入同策略，不使用扩展名过滤（低版本 Android SAF
  /// MIME 匹配问题），解析失败由提示兜底。
  Future<void> _importFromFile() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.platform.pickFiles();
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.single.path;
      if (path == null) {
        messenger.showSnackBar(const SnackBar(content: Text('无法获取文件路径')));
        return;
      }
      final text = await File(path).readAsString();
      if (!mounted) return;
      await _parseAndConfirm(text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('从文件导入失败：$e')));
      }
    }
  }

  /// 解析替换规则文本（对标原版 ImportReplaceRuleDialog 容错：
  /// 数组 / {"replaceRules": [...]} / 单对象均可）
  List<Map<String, dynamic>> _parseRulesText(String text) {
    final decoded = jsonDecode(text.trim());
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (decoded is Map) {
      final list = decoded['replaceRules'];
      if (list is List) {
        return list
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return [Map<String, dynamic>.from(decoded)];
    }
    throw const FormatException('格式错误，未解析到替换规则');
  }

  /// 候选规则 → 导入确认页（对标原版 comparisonSource 流程：
  /// 用户勾选确认后才入库）
  Future<void> _parseAndConfirm(String text) async {
    List<Map<String, dynamic>> candidates;
    try {
      candidates = _parseRulesText(text);
    } catch (_) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('格式错误，未解析到替换规则')));
      return;
    }
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('格式错误，未解析到替换规则')));
      return;
    }
    if (!mounted) return;
    final localRules = ref.read(replaceRuleNotifierProvider).rules;
    final imported = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ReplaceRuleImportConfirmScreen(
          raws: candidates,
          localRules: localRules,
        ),
      ),
    );
    if (!mounted) return;
    // 确认页返回导入成功条数；取消返回 null/0
    if (imported != null && imported > 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入完成（$imported 条）')));
    }
  }

  void _confirmDelete(
    BuildContext context,
    ReplaceRuleNotifier provider,
    ReplaceRule rule,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${rule.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              provider.deleteRule(rule.id);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('规则已删除')));
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

class _ReplaceRuleTile extends StatelessWidget {
  final ReplaceRule rule;
  final int index;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// [批12] 筛选/搜索/分组子集态禁用拖拽手柄（子集无法安全全量重排）
  final bool showDragHandle;

  // [UI-fix v2.0.2 | 2026-08-06] 批量模式支持 — Qoder
  final bool batchMode;
  final bool selected;
  final VoidCallback? onSelect;
  final VoidCallback? onEnterBatch;

  const _ReplaceRuleTile({
    super.key,
    required this.rule,
    required this.index,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.showDragHandle = true,
    this.batchMode = false,
    this.selected = false,
    this.onSelect,
    this.onEnterBatch,
  });

  /// [批12 P3] 48×48 拖拽手柄命中层（图标居中 24dp）
  ///
  /// 原实现只包裸 24dp `Icon`，真实手指容错偏小（y 偏移 19px 即被滚动手势
  /// 接管）；扩到 Material 建议的最小触控目标。行高由 Switch/IconButton
  /// 的 48dp 决定，48dp 手柄不改变行高。
  ///
  /// **命中修复**：`SizedBox`/`Center` 无绘制、无自身命中，而
  /// `ReorderableDragStartListener` 内部 `Listener` 默认
  /// `HitTestBehavior.deferToChild`——透明外圈不会进入命中路径。用
  /// `ColoredBox(Colors.transparent)` 包住 48×48：透明色仍按 opaque 行为
  /// 参与命中，整个命中区都能起拖。
  Widget _buildDragHandleIcon(Color color) {
    return SizedBox(
      key: ValueKey('replace-rule-drag-handle-${rule.id}'),
      width: 48,
      height: 48,
      child: ColoredBox(
        color: Colors.transparent,
        child: Center(
          child: Icon(Symbols.drag_handle_rounded, size: 24, color: color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      // [LAYOUT_PLAN P2] 分组卡圆角 16dp；边距 horizontal16（全局标尺）
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: batchMode ? onSelect : onEdit,
        onLongPress: batchMode ? onSelect : onEnterBatch,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          // [LAYOUT_PLAN P2] 组内行 vertical12/horizontal8
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(
            children: [
              // [UI-fix v2.0.2 | 2026-08-06] 批量模式显示选中框，否则排序手柄 — Qoder
              if (batchMode)
                Checkbox(value: selected, onChanged: (_) => onSelect?.call())
              else if (showDragHandle)
                // [批12 P3] 排序手柄：48×48 透明命中层（Material 最小触控目标），
                // 图标仍居中 24dp；监听器包住整个命中区域
                Semantics(
                  label: '拖动排序',
                  button: true,
                  child: ReorderableDragStartListener(
                    index: index,
                    child: _buildDragHandleIcon(theme.colorScheme.outline),
                  ),
                )
              else
                // [批12] 子集筛选态：手柄置灰且不挂拖拽监听（保持同尺寸不跳动）
                _buildDragHandleIcon(theme.colorScheme.outlineVariant),
              const SizedBox(width: 8),
              // 规则信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name.isEmpty ? '(未命名)' : rule.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${rule.isRegex ? "正则" : "文本"}: ${rule.pattern} → ${rule.replacement}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        // [FIX 2026-09-04] 正文次要文字走 onSurfaceVariant（outline 仅用于边框/装饰图标）
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (rule.scope != null && rule.scope!.isNotEmpty)
                      Text(
                        '范围: ${rule.scope}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                  ],
                ),
              ),
              // 启用开关（对标 swt_enabled）
              // [LAYOUT_PLAN P2] 开关行无 Chevron；标题/副标题走 M3 Type Scale
              Switch(value: rule.isEnabled, onChanged: onToggle),
              if (!batchMode) ...[
                // 编辑（对标 iv_edit）
                IconButton(
                  icon: Icon(
                    Symbols.edit_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: '编辑',
                  onPressed: onEdit,
                ),
                // 更多菜单（对标 iv_menu_more）
                PopupMenuButton<String>(
                  icon: Icon(
                    Symbols.more_vert_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: '更多',
                  onSelected: (v) {
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// [UI-fix v2.0.2 | 2026-08-06] 网络导入 URL 输入对话框
///（对标原版 InputDialog：输入框 + 历史记录） — Qoder
class _ImportUrlDialog extends StatefulWidget {
  final List<String> history;

  const _ImportUrlDialog({required this.history});

  @override
  State<_ImportUrlDialog> createState() => _ImportUrlDialogState();
}

class _ImportUrlDialogState extends State<_ImportUrlDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('从 URL 导入替换规则'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: widget.history.isEmpty,
              decoration: const InputDecoration(hintText: '输入替换规则 URL 地址'),
              keyboardType: TextInputType.url,
            ),
            if (widget.history.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('历史记录', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              for (final url in widget.history)
                InkWell(
                  onTap: () => Navigator.pop(context, url),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final url = _controller.text.trim();
            if (url.isEmpty) return;
            Navigator.pop(context, url);
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}
