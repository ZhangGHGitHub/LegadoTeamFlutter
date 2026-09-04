import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import '../services/bridge_http.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/replace_rule/replace_rule_notifier.dart';
import '../routes.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/replace_rule_group_manage_dialog.dart';
import 'replace_rule_import_confirm_screen.dart';

/// 替换规则管理页面
class ReplaceRulesScreen extends ConsumerStatefulWidget {
  // [UI-fix v2.0.2 | 2026-08-06] 路由参数：新规则 pattern 预填（阅读器
  // 长按选中文本传入，对标原版 ReplaceEditActivity 预填） — Qoder
  final String? initialPattern;

  const ReplaceRulesScreen({super.key, this.initialPattern});

  @override
  ConsumerState<ReplaceRulesScreen> createState() =>
      _ReplaceRulesScreenState();
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
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(replaceRuleNotifierProvider.notifier).load();
      // 路由预填 pattern：首帧后直接打开新建规则表单（pattern 已预填）
      final pattern = widget.initialPattern;
      if (mounted && pattern != null && pattern.isNotEmpty) {
        _showRuleForm(context, prefillPattern: pattern);
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
    return Scaffold(
      // 对齐原版 activity_replace_rule.xml：TitleBar 内嵌 view_search 搜索框
      appBar: _batchMode ? _buildBatchAppBar() : LegadoAppBar(
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
                color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.6),
              ),
              prefixIcon: Icon(
                Symbols.search_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.8),
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.2),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
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
              _groupFilter == null ? Symbols.filter_list_rounded : Symbols.filter_alt_rounded,
            ),
            onSelected: (v) => setState(() => _groupFilter = v),
            itemBuilder: (_) => [
              const PopupMenuItem<String?>(value: null, child: Text('全部')),
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
            onPressed: () => showHelp(context, HelpAssets.replaceRuleHelp),
          ),
          IconButton(
            icon: const Icon(Symbols.add_rounded),
            onPressed: () => _showRuleForm(context),
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
      return ListView.builder(
        itemCount: rules.length,
        itemBuilder: (context, index) {
          final rule = rules[index];
          return _ReplaceRuleTile(
            key: ValueKey(rule.id),
            rule: rule,
            index: index,
            total: rules.length,
            batchMode: true,
            selected: _selected.contains(rule.id),
            onSelect: () => _toggleSelect(rule.id),
            onToggle: (enabled) => provider.setEnabled(rule.id, enabled),
            onEdit: () => _toggleSelect(rule.id),
            onDelete: () => _confirmDelete(context, provider, rule),
            onMoveUp: () => provider.moveUp(index),
            onMoveDown: () => provider.moveDown(index),
          );
        },
      );
    }
    return ReorderableListView.builder(
      itemCount: rules.length,
      onReorderItem: (oldIndex, newIndex) {
        // 简单的排序处理
        if (oldIndex < newIndex) {
          for (var i = oldIndex; i < newIndex; i++) {
            provider.moveDown(i);
          }
        } else {
          for (var i = oldIndex; i > newIndex; i--) {
            provider.moveUp(i);
          }
        }
      },
      itemBuilder: (context, index) {
        final rule = rules[index];
        return _ReplaceRuleTile(
          key: ValueKey(rule.id),
          rule: rule,
          index: index,
          total: rules.length,
          onToggle: (enabled) => provider.setEnabled(rule.id, enabled),
          onEdit: () => _showRuleForm(context, rule: rule),
          onDelete: () => _confirmDelete(context, provider, rule),
          onMoveUp: () => provider.moveUp(index),
          onMoveDown: () => provider.moveDown(index),
          onEnterBatch: () => _enterBatch(rule.id),
        );
      },
    );
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
          (r) =>
              r.group?.split(',').map((e) => e.trim()).contains(g) ?? false,
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
        await notifier.moveToTop(ids);
        _exitBatch();
      case 'bottom':
        await notifier.moveToBottom(ids);
        _exitBatch();
      case 'export':
        await _exportSelected(ids);
    }
  }

  /// 导出选中规则（对标原版 menu_export_selection：JSON 分享）
  Future<void> _exportSelected(List<int> ids) async {
    final rules = ref
        .read(replaceRuleNotifierProvider)
        .rules
        .where((r) => ids.contains(r.id))
        .toList();
    if (rules.isEmpty) return;
    final json = const JsonEncoder.withIndent('  ')
        .convert(rules.map((r) => r.toJson()).toList());
    try {
      await Share.share(json, subject: 'Legado 替换规则');
      if (mounted) _exitBatch();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  /// [UI-fix v2.0.1 | 2026-08-06] 导入菜单分发
  /// [UI-fix v2.0.2 | 2026-08-06] 网络/二维码导入接通（复用导入确认页） — Qoder
  void _handleImportMenu(String value) {
    switch (value) {
      case 'local':
        _importFromFile();
      case 'online':
        _showImportUrlDialog();
      case 'qrcode':
        _importFromQrCode();
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取替换规则失败：$e')),
        );
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('扫码内容不是可识别的替换规则数据')),
    );
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
        messenger.showSnackBar(
          const SnackBar(content: Text('无法获取文件路径')),
        );
        return;
      }
      final text = await File(path).readAsString();
      if (!mounted) return;
      await _parseAndConfirm(text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('从文件导入失败：$e')),
        );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('格式错误，未解析到替换规则')),
      );
      return;
    }
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('格式错误，未解析到替换规则')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入完成（$imported 条）')),
      );
    }
  }

  void _showRuleForm(BuildContext context, {ReplaceRule? rule, String? prefillPattern}) {
    final isEdit = rule != null;
    final nameCtrl = TextEditingController(text: rule?.name ?? '');
    final groupCtrl = TextEditingController(text: rule?.group ?? '');
    final patternCtrl = TextEditingController(
      text: rule?.pattern ?? prefillPattern ?? '',
    );
    final replacementCtrl = TextEditingController(
      text: rule?.replacement ?? '',
    );
    final scopeCtrl = TextEditingController(text: rule?.scope ?? '');
    final excludeScopeCtrl = TextEditingController(
      text: rule?.excludeScope ?? '',
    );
    final timeoutCtrl = TextEditingController(
      text: (rule?.timeoutMillisecond ?? 3000).toString(),
    );
    var isRegex = rule?.isRegex ?? true;
    var scopeTitle = rule?.scopeTitle ?? false;
    var scopeContent = rule?.scopeContent ?? true;
    var isEnabled = rule?.isEnabled ?? true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(isEdit ? '编辑替换规则' : '添加替换规则'),
          content: SingleChildScrollView(
            child: Column(
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
                  controller: groupCtrl,
                  decoration: const InputDecoration(
                    labelText: '分组',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: patternCtrl,
                  decoration: const InputDecoration(
                    labelText: '匹配模式',
                    hintText: '正则表达式或文本',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('正则表达式'),
                  value: isRegex,
                  onChanged: (v) => setState(() => isRegex = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                TextField(
                  controller: replacementCtrl,
                  decoration: const InputDecoration(
                    labelText: '替换为',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('作用于标题'),
                  value: scopeTitle,
                  onChanged: (v) => setState(() => scopeTitle = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile(
                  title: const Text('作用于正文'),
                  value: scopeContent,
                  onChanged: (v) => setState(() => scopeContent = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                TextField(
                  controller: scopeCtrl,
                  decoration: const InputDecoration(
                    labelText: '作用范围',
                    hintText: '留空或 global 为全局，输入书名为特定书籍',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: excludeScopeCtrl,
                  decoration: const InputDecoration(
                    labelText: '排除范围',
                    hintText: '输入书名，多个用逗号分隔',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: timeoutCtrl,
                  decoration: const InputDecoration(
                    labelText: '超时时间（毫秒）',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('启用'),
                  value: isEnabled,
                  onChanged: (v) => setState(() => isEnabled = v),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final newRule = ReplaceRule(
                  id: rule?.id ?? 0,
                  name: nameCtrl.text,
                  group: groupCtrl.text.isEmpty ? null : groupCtrl.text,
                  pattern: patternCtrl.text,
                  replacement: replacementCtrl.text,
                  scope: scopeCtrl.text.isEmpty ? null : scopeCtrl.text,
                  scopeTitle: scopeTitle,
                  scopeContent: scopeContent,
                  excludeScope: excludeScopeCtrl.text.isEmpty
                      ? null
                      : excludeScopeCtrl.text,
                  isRegex: isRegex,
                  isEnabled: isEnabled,
                  timeoutMillisecond: int.tryParse(timeoutCtrl.text) ?? 3000,
                  order: rule?.order ?? 0,
                );
                final provider = ref.read(replaceRuleNotifierProvider.notifier);
                if (isEdit) {
                  provider.updateRule(newRule);
                } else {
                  provider.addRule(newRule);
                }
                Navigator.of(ctx).pop();
              },
              child: Text(isEdit ? '保存' : '添加'),
            ),
          ],
        ),
      ),
    );
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
  final int total;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  // [UI-fix v2.0.2 | 2026-08-06] 批量模式支持 — Qoder
  final bool batchMode;
  final bool selected;
  final VoidCallback? onSelect;
  final VoidCallback? onEnterBatch;

  const _ReplaceRuleTile({
    super.key,
    required this.rule,
    required this.index,
    required this.total,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    this.batchMode = false,
    this.selected = false,
    this.onSelect,
    this.onEnterBatch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: batchMode ? onSelect : onEdit,
        onLongPress: batchMode ? onSelect : onEnterBatch,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // [UI-fix v2.0.2 | 2026-08-06] 批量模式显示选中框，否则排序手柄 — Qoder
              if (batchMode)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onSelect?.call(),
                )
              else
                // 排序手柄
                ReorderableDragStartListener(
                  index: index,
                  child: Icon(
                    Symbols.drag_handle_rounded,
                    color: theme.colorScheme.outline,
                  ),
                ),
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
              decoration: const InputDecoration(
                hintText: '输入替换规则 URL 地址',
              ),
              keyboardType: TextInputType.url,
            ),
            if (widget.history.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '历史记录',
                style: Theme.of(context).textTheme.labelMedium,
              ),
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
