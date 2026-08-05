import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/rule_sub/rule_sub_notifier.dart';
import '../providers/source/source_notifier.dart';
import '../services/source_import_service.dart' show SourcePreview;
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_source_import_confirm_screen.dart';
import 'replace_rule_import_confirm_screen.dart';
import 'source_import_confirm_screen.dart';

/// 规则订阅管理页（对标原版 RuleSubActivity）
///
/// 功能对齐：
/// - 列表（类型标签 + 名称 + URL）、拖拽排序（customOrder 持久化）
/// - 新增/编辑弹窗（类型/名称/URL/自动更新/静默更新/更新间隔，联动逻辑同原版）
/// - 点击条目按类型打开对应导入流程（书源/订阅源/替换规则）
/// - 更多菜单：编辑 / 检查更新 / 应用更新 / 删除（后两项为 Rust 轨扩展）
class RuleSubScreen extends ConsumerStatefulWidget {
  const RuleSubScreen({super.key});

  @override
  ConsumerState<RuleSubScreen> createState() => _RuleSubScreenState();
}

class _RuleSubScreenState extends ConsumerState<RuleSubScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(ruleSubNotifierProvider.notifier).loadSubs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ruleSubNotifierProvider);

    return Scaffold(
      // 原版顶栏：标题「规则订阅」+ 新增按钮（menu_add）
      appBar: AppBar(
        title: const Text('规则订阅'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增订阅',
            onPressed: () => _showEditDialog(context, null),
          ),
        ],
      ),
      body: _buildBody(context, state),
    );
  }

  Widget _buildBody(BuildContext context, RuleSubState state) {
    if (state.loading && state.subs.isEmpty) {
      return const LoadingIndicator(message: '加载订阅...');
    }
    if (state.error != null && state.subs.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(ruleSubNotifierProvider.notifier).loadSubs(),
      );
    }
    if (state.subs.isEmpty) {
      return const EmptyState(
        icon: Icons.rss_feed_outlined,
        title: '暂无订阅',
        subtitle: '点击右上角「新增订阅」添加书源/订阅源/替换规则订阅',
      );
    }

    final subs = state.subs;
    return ReorderableListView.builder(
      // 原版 RecyclerView + ItemTouchHelper 拖拽排序
      buildDefaultDragHandles: true,
      itemCount: subs.length,
      onReorder: (oldIndex, newIndex) =>
          ref.read(ruleSubNotifierProvider.notifier).reorder(oldIndex, newIndex),
      itemBuilder: (context, index) {
        final sub = subs[index];
        return _buildSubItem(context, sub, key: ValueKey(sub.id));
      },
    );
  }

  /// 订阅列表项（对标 item_rule_sub.xml：类型标签 + 名称 + URL +
  /// 编辑/更多图标；点击条目按类型打开导入）
  Widget _buildSubItem(BuildContext context, RuleSub sub, {required Key key}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openSubscription(context, sub),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              // 类型标签（对标 tv_type）
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  sub.typeLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // 名称 + URL（对标 tv_name / tv_url）
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sub.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        color: sub.isEnabled
                            ? colorScheme.onSurface
                            : colorScheme.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                    Text(
                      sub.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 启用开关（Rust 轨扩展 is_enabled）
              Switch(
                value: sub.isEnabled,
                onChanged: (v) => ref
                    .read(ruleSubNotifierProvider.notifier)
                    .setEnabled(sub.id, v),
              ),
              // 编辑图标（对标 iv_edit）
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: '编辑',
                visualDensity: VisualDensity.compact,
                onPressed: () => _showEditDialog(context, sub),
              ),
              // 更多图标（对标 iv_menu_more）
              IconButton(
                icon: const Icon(Icons.more_vert, size: 20),
                tooltip: '更多选项',
                visualDensity: VisualDensity.compact,
                onPressed: () => _showSubMenu(context, sub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 更多菜单（原版仅删除；检查更新/应用更新为 Rust 轨扩展能力）
  Future<void> _showSubMenu(BuildContext context, RuleSub sub) async {
    final colorScheme = Theme.of(context).colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              onTap: () => Navigator.pop(ctx, 'check_update'),
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('应用更新'),
              onTap: () => Navigator.pop(ctx, 'apply_update'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colorScheme.error),
              title:
                  Text('删除', style: TextStyle(color: colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    final notifier = ref.read(ruleSubNotifierProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'check_update':
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator()),
        );
        Map<String, dynamic> result;
        try {
          result = await notifier.checkUpdate(sub.id);
        } catch (e) {
          if (context.mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
          messenger.showSnackBar(
            SnackBar(content: Text('检查更新失败：$e')),
          );
          return;
        }
        if (!context.mounted) return;
        Navigator.of(context).pop(); // 关闭加载指示
        final error = (result['error'] ?? '').toString();
        final hasUpdate = result['hasUpdate'] == true;
        final version = (result['remoteVersion'] ?? '').toString();
        messenger.showSnackBar(SnackBar(
          content: Text(error.isNotEmpty
              ? '检查更新失败：$error'
              : (hasUpdate
                  ? '发现新版本${version.isNotEmpty ? '：$version' : ''}'
                  : '已是最新版本')),
        ));
      case 'apply_update':
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator()),
        );
        Map<String, dynamic> result;
        try {
          result = await notifier.applyUpdate(sub.id);
        } catch (e) {
          if (context.mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
          messenger.showSnackBar(
            SnackBar(content: Text('应用更新失败：$e')),
          );
          return;
        }
        if (!context.mounted) return;
        Navigator.of(context).pop(); // 关闭加载指示
        final error = (result['error'] ?? '').toString();
        if (error.isNotEmpty || result['success'] != true) {
          messenger.showSnackBar(SnackBar(
            content: Text('应用更新失败：${error.isEmpty ? '未知错误' : error}'),
          ));
        } else {
          final added = (result['itemsAdded'] ?? 0).toString();
          final updated = (result['itemsUpdated'] ?? 0).toString();
          final removed = (result['itemsRemoved'] ?? 0).toString();
          messenger.showSnackBar(SnackBar(
            content: Text('更新完成：新增 $added、更新 $updated、移除 $removed'),
          ));
        }
      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: '删除订阅',
          content: '确定要删除订阅「${sub.name}」吗？',
          confirmText: '删除',
          isDestructive: true,
        );
        if (confirmed && context.mounted) {
          await notifier.deleteSub(sub.id);
        }
    }
  }

  /// 新增/编辑订阅弹窗（对标原版 editSubscription）
  Future<void> _showEditDialog(BuildContext context, RuleSub? existing) async {
    final result = await showDialog<RuleSub>(
      context: context,
      builder: (_) => _RuleSubEditDialog(sub: existing),
    );
    if (result == null || !context.mounted) return;

    final notifier = ref.read(ruleSubNotifierProvider.notifier);
    // URL 重复检查（对标原版 findByUrl 前置校验）
    final duplicate =
        notifier.findDuplicate(result.url, excludeId: result.id);
    if (duplicate != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('URL 已存在（${duplicate.name}）')),
      );
      return;
    }
    await notifier.saveSub(result);
  }

  /// 点击条目按类型打开导入（对标原版 openSubscription）
  Future<void> _openSubscription(BuildContext context, RuleSub sub) async {
    switch (sub.subType) {
      case RuleSub.bookSource:
        await _importBookSources(context, sub);
      case RuleSub.rssSource:
        await _importRssSources(context, sub);
      case RuleSub.replaceRule:
        await _importReplaceRules(context, sub);
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('未知订阅类型：${sub.subType}')),
        );
    }
  }

  /// 书源订阅导入（对标 ImportBookSourceDialog：拉取→勾选确认→入库）
  Future<void> _importBookSources(BuildContext context, RuleSub sub) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    List<SourcePreview> sources;
    try {
      sources = await ref
          .read(sourceNotifierProvider.notifier)
          .importService
          .fetchSourcesFromUrl(sub.url);
    } catch (e) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      messenger.showSnackBar(
        SnackBar(content: Text('获取书源失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载指示

    if (sources.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('格式错误，未解析到书源')),
      );
      return;
    }

    final localSources = ref.read(sourceNotifierProvider).sources;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SourceImportConfirmScreen(
          sources: sources,
          localSources: localSources,
        ),
      ),
    );
    if (ok == true && mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('导入完成')));
    }
  }

  /// 订阅源导入（对标 ImportRssSourceDialog：拉取→勾选确认→入库）
  Future<void> _importRssSources(BuildContext context, RuleSub sub) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    List<dynamic> items;
    try {
      items = await _fetchJsonArray(sub.url);
    } catch (e) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      messenger.showSnackBar(
        SnackBar(content: Text('获取订阅源失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载指示

    if (items.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('格式错误，未解析到订阅源')),
      );
      return;
    }

    final candidates = [
      for (final item in items)
        if (item is Map<String, dynamic>) item,
    ];
    // 本地订阅源用于新增/更新状态判定与保留选项合并
    List<RssSource> localSources;
    try {
      localSources = await ref.read(bookApiProvider).getRssSources();
    } catch (_) {
      localSources = [];
    }
    if (!mounted) return;

    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RssSourceImportConfirmScreen(
          sources: candidates,
          localSources: localSources,
        ),
      ),
    );
    if (ok == true && mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('导入完成')));
    }
  }

  /// 替换规则导入（对标 ImportReplaceRuleDialog：拉取→勾选确认→入库）
  Future<void> _importReplaceRules(BuildContext context, RuleSub sub) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    List<dynamic> items;
    try {
      items = await _fetchJsonArray(sub.url);
    } catch (e) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      messenger.showSnackBar(
        SnackBar(content: Text('获取替换规则失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载指示

    if (items.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('格式错误，未解析到替换规则')),
      );
      return;
    }

    final candidates = [
      for (final item in items)
        if (item is Map<String, dynamic>) item,
    ];
    // 本地规则用于新增/更新状态判定与同 id 更新入库
    List<ReplaceRule> localRules;
    try {
      localRules = await ref.read(bookApiProvider).getReplaceRules();
    } catch (_) {
      localRules = [];
    }
    if (!mounted) return;

    final count = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ReplaceRuleImportConfirmScreen(
          raws: candidates,
          localRules: localRules,
        ),
      ),
    );
    if (count != null && count > 0 && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text('已导入 $count 条替换规则')),
      );
    }
  }

  /// 拉取订阅 URL 并解析为 JSON 数组（对象包装时收拢为单元素数组）
  Future<List<dynamic>> _fetchJsonArray(String url) async {
    final response =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is List) return decoded;
    if (decoded is Map<String, dynamic>) return [decoded];
    throw const FormatException('订阅内容不是 JSON 数组或对象');
  }
}

/// 订阅编辑对话框内容（对标 dialog_rule_sub_edit.xml：
/// 类型下拉 + 名称 + URL + 自动更新 + 静默更新 + 更新间隔）
///
/// controller 生命周期绑定对话框子树（随子树卸载统一释放）。
/// 联动逻辑严格对齐原版：
/// - 开启自动更新且间隔为 0 → 默认填 24
/// - 关闭自动更新 → 间隔归 0
/// - 间隔输入 0 → 清除并禁用自动更新/静默更新
class _RuleSubEditDialog extends StatefulWidget {
  /// 为 null 表示新增（customOrder 由 Notifier 追加到末尾）
  final RuleSub? sub;

  const _RuleSubEditDialog({this.sub});

  @override
  State<_RuleSubEditDialog> createState() => _RuleSubEditDialogState();
}

class _RuleSubEditDialogState extends State<_RuleSubEditDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _intervalCtrl = TextEditingController();

  late String _type;
  late bool _autoUpdate;
  late bool _silentUpdate;

  @override
  void initState() {
    super.initState();
    final sub = widget.sub;
    _type = sub?.subType ?? RuleSub.bookSource;
    _nameCtrl.text = sub?.name ?? '';
    _urlCtrl.text = sub?.url ?? '';
    _autoUpdate = sub?.autoUpdate ?? false;
    _silentUpdate = sub?.silentUpdate ?? false;
    _intervalCtrl.text = (sub?.updateInterval ?? 0).toString();
    // 对标原版：间隔文本变化联动自动更新/静默更新可用性
    _intervalCtrl.addListener(_onIntervalChanged);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _intervalCtrl.dispose();
    super.dispose();
  }

  void _onIntervalChanged() {
    final value = int.tryParse(_intervalCtrl.text.trim()) ?? -1;
    setState(() {
      if (value == 0) {
        _autoUpdate = false;
        _silentUpdate = false;
      }
    });
  }

  void _onAutoUpdateChanged(bool checked) {
    setState(() {
      _autoUpdate = checked;
      if (checked && (int.tryParse(_intervalCtrl.text) ?? 0) == 0) {
        // 对标原版：开启自动更新且间隔为 0 时默认 24 小时
        _intervalCtrl.text = '24';
      } else if (!checked) {
        _intervalCtrl.text = '0';
        _silentUpdate = false;
      }
    });
  }

  bool get _intervalEnabled => _autoUpdate;

  bool get _silentEnabled =>
      _autoUpdate && (int.tryParse(_intervalCtrl.text) ?? 0) > 0;

  void _confirm() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL 不能为空')),
      );
      return;
    }
    final interval = int.tryParse(_intervalCtrl.text.trim()) ?? 0;
    final existing = widget.sub;
    Navigator.pop(
      context,
      (existing ?? const RuleSub()).copyWith(
        name: _nameCtrl.text.trim(),
        url: url,
        subType: _type,
        autoUpdate: _autoUpdate && interval > 0,
        silentUpdate: _silentUpdate && interval > 0,
        updateInterval: _autoUpdate ? interval : 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final intervalEnabled = _intervalEnabled;
    final silentEnabled = _silentEnabled;
    // 禁用态文字色（对标原版 isEnabled=false 的置灰效果）
    final disabledColor = colorScheme.onSurface.withValues(alpha: 0.4);
    return AlertDialog(
      title: const Text('规则订阅'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 类型下拉（对标 sp_type：书源/订阅源/替换规则）
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: '类型'),
              items: const [
                DropdownMenuItem(
                  value: RuleSub.bookSource,
                  child: Text('书源'),
                ),
                DropdownMenuItem(
                  value: RuleSub.rssSource,
                  child: Text('订阅源'),
                ),
                DropdownMenuItem(
                  value: RuleSub.replaceRule,
                  child: Text('替换规则'),
                ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _type = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(labelText: 'URL'),
            ),
            const SizedBox(height: 12),
            // 原版单行水平布局（dialog_rule_sub_edit.xml L55-99）：
            // 自动更新 | 静默更新 | 更新间隔输入 + 小时；窄屏自动换行
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 4,
              children: [
                _buildCheckText(
                  '自动更新',
                  _autoUpdate,
                  _onAutoUpdateChanged,
                ),
                _buildCheckText(
                  '静默更新',
                  _silentUpdate && silentEnabled,
                  silentEnabled
                      ? (v) => setState(() => _silentUpdate = v)
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '更新间隔',
                    style: TextStyle(
                      fontSize: 14,
                      color: intervalEnabled
                          ? colorScheme.onSurface
                          : disabledColor,
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: TextField(
                    controller: _intervalCtrl,
                    enabled: intervalEnabled,
                    keyboardType: TextInputType.number,
                    // 对标原版 digits="0123456789"
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      hintText: '24',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    '小时',
                    style: TextStyle(
                      fontSize: 14,
                      color: intervalEnabled
                          ? colorScheme.onSurface
                          : disabledColor,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('确定'),
        ),
      ],
    );
  }

  /// 紧凑勾选框 + 标签（对标原版 CheckBox 水平排布，整块可点）
  Widget _buildCheckText(
    String label,
    bool value,
    ValueChanged<bool>? onChanged,
  ) {
    final enabled = onChanged != null;
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: enabled ? (v) => onChanged(v ?? false) : null,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: enabled
                    ? colorScheme.onSurface
                    : colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
