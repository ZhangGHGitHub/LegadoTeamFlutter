import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/md3_fast_scroller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import '../services/bridge_http.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/rss/rss_notifier.dart' show syncDefaultRssSources;
import '../routes.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/rss_group_manage_dialog.dart';
import '../utils/error_message.dart';
import 'rss_source_edit_screen.dart';
import 'rss_source_import_confirm_screen.dart';

/// 安卓端 AppPattern.splitGroupRegex：[,;，；]
final RegExp _splitGroupRegex = RegExp(r'[,;，；]');

/// 订阅源管理页（对标原版 RssSourceActivity）
///
/// - 顶栏：搜索框（特殊过滤词：启用/禁用/需登录/未分组/group:分组名）
///   + 分组菜单（分组管理/特殊分组/动态分组）+ 更多菜单（新增/导入/帮助）
/// - 列表项：勾选框 + 源名(分组) + 启用开关 + 编辑 + 更多（置顶/置底/删除）
/// - 拖拽排序（customOrder）、长按无（拖拽占用），勾选框进入批量模式
/// - 批量操作：全选/反选/删除 + 更多（启停/分组/置顶置底/导出/分享/区间）
class RssSourceManageScreen extends ConsumerStatefulWidget {
  const RssSourceManageScreen({super.key});

  @override
  ConsumerState<RssSourceManageScreen> createState() =>
      _RssSourceManageScreenState();
}

class _RssSourceManageScreenState extends ConsumerState<RssSourceManageScreen> {
  // [UI_SYNC_REFACTOR R3] 快速滚动条控制器
  final ScrollController _fsController = ScrollController();
  final _searchCtrl = TextEditingController();

  List<RssSource> _sources = [];
  bool _loading = true;
  String? _error;

  /// 搜索关键词（驱动全部过滤，对标原版 searchView 单一入口）
  String _keyword = '';

  /// 批量选择模式（对标原版 SelectActionBar）
  bool _batchMode = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getRssSources();
      // 对标原版默认 customOrder 升序
      sources.sort((a, b) => a.customOrder.compareTo(b.customOrder));
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _loading = false;
        _selected.removeWhere((url) => sources.every((s) => s.sourceUrl != url));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e);
        _loading = false;
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ===== 过滤（对标原版 upSourceFlow） =====

  List<String> _splitGroups(String? sourceGroup) {
    if (sourceGroup == null || sourceGroup.isEmpty) return const [];
    return sourceGroup
        .split(_splitGroupRegex)
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }

  /// 聚合所有源分组（LinkedHashSet 保序，对标原版 linkedSetOf）
  List<String> get _groups {
    final set = <String>{};
    for (final s in _sources) {
      set.addAll(_splitGroups(s.sourceGroup));
    }
    return set.toList();
  }

  List<RssSource> get _filtered {
    final kw = _keyword.trim();
    if (kw.isEmpty) return _sources;
    switch (kw) {
      case '启用':
        return _sources.where((s) => s.enabled).toList();
      case '禁用':
        return _sources.where((s) => !s.enabled).toList();
      case '需登录':
        return _sources
            .where((s) => (s.loginUrl ?? '').trim().isNotEmpty)
            .toList();
      case '未分组':
        return _sources.where((s) => _splitGroups(s.sourceGroup).isEmpty).toList();
    }
    if (kw.startsWith('group:')) {
      final group = kw.substring('group:'.length);
      return _sources
          .where((s) => _splitGroups(s.sourceGroup).contains(group))
          .toList();
    }
    final lower = kw.toLowerCase();
    return _sources
        .where((s) =>
            s.sourceName.toLowerCase().contains(lower) ||
            s.sourceUrl.toLowerCase().contains(lower))
        .toList();
  }

  /// 分组菜单点击 → 写入搜索框（对标原版 searchView.setQuery）
  void _setQuery(String query) {
    _searchCtrl.text = query;
    setState(() => _keyword = query);
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_batchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _batchMode) _exitBatch();
      },
      child: Scaffold(
        appBar: _batchMode ? _buildBatchAppBar() : _buildAppBar(),
        body: _buildBody(),
        // 底部常驻批量操作栏（对标原版 SelectActionBar + rss_source_sel.xml）
        bottomNavigationBar: _buildBatchBottomBar(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return LegadoAppBar(
      // 原版 TitleBar 内嵌搜索框：无标题文字
      titleSpacing: 8,
      title: SizedBox(
        height: 36,
        child: TextField(
          controller: _searchCtrl,
          style: TextStyle(color: colorScheme.onSurface),
          decoration: InputDecoration(
            hintText: '搜索订阅源',
            hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
            filled: true,
            fillColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            prefixIcon: Icon(Symbols.search_rounded,
                size: 20, color: colorScheme.onSurfaceVariant),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 36, minHeight: 36),
            suffixIcon: _keyword.isNotEmpty
                ? IconButton(
                    icon: Icon(Symbols.close_rounded,
                        size: 18, color: colorScheme.onSurfaceVariant),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _keyword = '');
                    },
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (v) => setState(() => _keyword = v),
        ),
      ),
      actions: [
        // 分组菜单（对标原版 rss_source.xml menu_group 子菜单）
        PopupMenuButton<String>(
          icon: const Icon(Symbols.groups_rounded),
          tooltip: '分组',
          position: PopupMenuPosition.under,
          onSelected: _handleGroupAction,
          itemBuilder: (context) => [
            const PopupMenuItem(
              enabled: false,
              child: Text('分组', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const PopupMenuItem(
                value: 'group_manage', child: Text('分组管理')),
            CheckedPopupMenuItem(
              value: '启用',
              checked: _keyword.trim() == '启用',
              child: const Text('已启用'),
            ),
            CheckedPopupMenuItem(
              value: '禁用',
              checked: _keyword.trim() == '禁用',
              child: const Text('已禁用'),
            ),
            CheckedPopupMenuItem(
              value: '需登录',
              checked: _keyword.trim() == '需登录',
              child: const Text('需登录'),
            ),
            CheckedPopupMenuItem(
              value: '未分组',
              checked: _keyword.trim() == '未分组',
              child: const Text('未分组'),
            ),
            for (final group in _groups)
              CheckedPopupMenuItem(
                value: 'group:$group',
                checked: _keyword.trim() == 'group:$group',
                child: Text(group),
              ),
          ],
        ),
        // 更多菜单（对标原版 rss_source.xml 溢出菜单）
        PopupMenuButton<String>(
          tooltip: '更多选项',
          position: PopupMenuPosition.under,
          onSelected: _handleAction,
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'new',
              child: _MenuRow(icon: Symbols.add_rounded, label: '新增订阅源'),
            ),
            const PopupMenuItem(
              value: 'import_file',
              child: _MenuRow(icon: Symbols.download_rounded, label: '本地导入'),
            ),
            const PopupMenuItem(
              value: 'import_url',
              child: _MenuRow(icon: Symbols.cloud_download_rounded, label: '网络导入'),
            ),
            const PopupMenuItem(
              value: 'import_qr',
              child: _MenuRow(icon: Symbols.qr_code_rounded, label: '二维码导入'),
            ),
            const PopupMenuItem(
              value: 'import_default',
              child:
                  _MenuRow(icon: Symbols.auto_fix_high_rounded, label: '导入默认规则'),
            ),
            // 规则订阅入口（对标原版 RssFragment 列表头部
            // 「规则订阅」header item → RuleSubActivity；Flutter 侧
            // 统一收进溢出菜单，iOS 菜单惯例）
            const PopupMenuItem(
              value: 'rule_sub',
              child: _MenuRow(
                icon: Symbols.rss_feed_rounded,
                label: '规则订阅',
              ),
            ),
            const PopupMenuItem(
              value: 'help',
              child: _MenuRow(icon: Symbols.help_rounded, label: '帮助'),
            ),
          ],
        ),
      ],
    );
  }

  /// 批量模式顶栏（对标原版 SelectActionBar：关闭 + 已选计数）
  PreferredSizeWidget _buildBatchAppBar() {
    return LegadoAppBar(
      leading: IconButton(
        icon: const Icon(Symbols.close_rounded),
        tooltip: '退出批量模式',
        onPressed: _exitBatch,
      ),
      title: Text('已选择 ${_selected.length} 项'),
    );
  }

  void _exitBatch() {
    setState(() {
      _batchMode = false;
      _selected.clear();
    });
  }

  /// 底部常驻批量操作栏（对标原版 rss_source_sel.xml）
  Widget _buildBatchBottomBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final filteredCount = _filtered.length;

    Widget barButton({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
      Color? color,
    }) {
      final effective = color ?? colorScheme.onSurface;
      final dim = onPressed == null;
      return Expanded(
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 22,
                    color: dim
                        ? effective.withValues(alpha: 0.35)
                        : effective),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: dim
                        ? effective.withValues(alpha: 0.35)
                        : effective,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.6),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              barButton(
                icon: _isAllSelected
                    ? Symbols.check_box_rounded
                    : Symbols.check_box_outline_blank_rounded,
                label: '全选 ${_selected.length}/$filteredCount',
                onPressed: () {
                  setState(() {
                    _batchMode = true;
                    if (_isAllSelected) {
                      _selected.clear();
                    } else {
                      _selected
                          .addAll(_filtered.map((s) => s.sourceUrl));
                    }
                  });
                },
              ),
              barButton(
                icon: Symbols.flip_rounded,
                label: '反选',
                onPressed: _filtered.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _batchMode = true;
                          for (final s in _filtered) {
                            if (_selected.contains(s.sourceUrl)) {
                              _selected.remove(s.sourceUrl);
                            } else {
                              _selected.add(s.sourceUrl);
                            }
                          }
                        });
                      },
              ),
              barButton(
                icon: Symbols.delete_rounded,
                label: '删除',
                color: colorScheme.error,
                onPressed: _selected.isEmpty
                    ? null
                    : () => _handleBatchAction('delete'),
              ),
              Expanded(
                child: PopupMenuButton<String>(
                  tooltip: '更多选项',
                  enabled: _selected.isNotEmpty,
                  onSelected: _handleBatchAction,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.more_horiz_rounded,
                          size: 22,
                          color: _selected.isEmpty
                              ? colorScheme.onSurface
                                  .withValues(alpha: 0.35)
                              : colorScheme.onSurface,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '更多选项',
                          style: TextStyle(
                            fontSize: 12,
                            color: _selected.isEmpty
                                ? colorScheme.onSurface
                                    .withValues(alpha: 0.35)
                                : colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 对标原版 rss_source_sel.xml 9 项选择操作
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'enable', child: Text('启用选中')),
                    PopupMenuItem(
                        value: 'disable', child: Text('禁用选中')),
                    PopupMenuItem(
                        value: 'add_group', child: Text('添加到分组')),
                    PopupMenuItem(
                        value: 'remove_group', child: Text('移除分组')),
                    PopupMenuItem(
                        value: 'top', child: Text('选中置顶')),
                    PopupMenuItem(
                        value: 'bottom', child: Text('选中置底')),
                    PopupMenuItem(
                        value: 'export', child: Text('导出选中')),
                    PopupMenuItem(
                        value: 'share', child: Text('分享源')),
                    PopupMenuItem(
                        value: 'select_range', child: Text('选择区间')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isAllSelected =>
      _filtered.isNotEmpty &&
      _filtered.every((s) => _selected.contains(s.sourceUrl));

  Widget _buildBody() {
    if (_loading && _sources.isEmpty) {
      return const LoadingIndicator(message: '加载订阅源...');
    }
    if (_error != null && _sources.isEmpty) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    final list = _filtered;
    if (list.isEmpty) {
      return EmptyState(
        icon: Symbols.rss_feed_rounded,
        title: _sources.isEmpty ? '暂无订阅源' : '没有匹配的订阅源',
        subtitle: _sources.isEmpty
            ? '点击右上角菜单「新增订阅源」或导入订阅源'
            : null,
      );
    }
    if (_batchMode) {
      // [UI_SYNC_REFACTOR R3] 批量模式快速滚动条
      return Md3FastScroller(
        controller: _fsController,
        child: ListView.separated(
          controller: _fsController,
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
          itemBuilder: (context, index) =>
              _buildBatchItem(context, list[index]),
        ),
      );
    }
    // 非批量 + 无过滤：支持拖拽排序（对标原版 itemTouchHelper）
    if (_keyword.trim().isEmpty) {
      return ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: list.length,
        itemBuilder: (context, index) => ReorderableDelayedDragStartListener(
          key: ValueKey(list[index].sourceUrl),
          index: index,
          child: _buildSourceItem(context, list[index]),
        ),
        onReorderItem: _reorder,
      );
    }
    // [UI_SYNC_REFACTOR R3] 过滤模式快速滚动条
    return Md3FastScroller(
      controller: _fsController,
      child: ListView.separated(
        controller: _fsController,
        itemCount: list.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
        itemBuilder: (context, index) => _buildSourceItem(context, list[index]),
      ),
    );
  }

  /// 列表项（对标原版 item_rss_source：勾选框 + 源名(分组) +
  /// Switch + 编辑 + 更多）
  Widget _buildSourceItem(BuildContext context, RssSource source) {
    final colorScheme = Theme.of(context).colorScheme;
    final group = source.sourceGroup ?? '';
    return InkWell(
      onTap: () => _openEdit(source),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 8, top: 4, bottom: 4),
        child: Row(
          children: [
            // 勾选框（对标原版 cb_source：点击进入批量选择）
            Checkbox(
              value: false,
              visualDensity: VisualDensity.compact,
              onChanged: (_) => setState(() {
                _batchMode = true;
                _selected.add(source.sourceUrl);
              }),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.sourceName.isEmpty
                        ? source.sourceUrl
                        : source.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16, color: colorScheme.onSurface),
                  ),
                  if (group.isNotEmpty)
                    Text(
                      group,
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
            // 启用开关（对标原版 swt_enabled）
            Switch(
              value: source.enabled,
              onChanged: (_) => _toggleSource(source),
            ),
            IconButton(
              icon: const Icon(Symbols.edit_rounded, size: 20),
              tooltip: '编辑',
              visualDensity: VisualDensity.compact,
              onPressed: () => _openEdit(source),
            ),
            IconButton(
              icon: const Icon(Symbols.more_vert_rounded, size: 20),
              tooltip: '更多选项',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showSourceMenu(source),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchItem(BuildContext context, RssSource source) {
    final selected = _selected.contains(source.sourceUrl);
    return ListTile(
      leading: Checkbox(
        value: selected,
        onChanged: (_) => _toggleSelection(source.sourceUrl),
      ),
      title: Text(
        source.sourceName.isEmpty ? source.sourceUrl : source.sourceName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        source.sourceGroup?.isNotEmpty == true
            ? source.sourceGroup!
            : '未分组',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => _toggleSelection(source.sourceUrl),
    );
  }

  void _toggleSelection(String sourceUrl) {
    setState(() {
      if (_selected.contains(sourceUrl)) {
        _selected.remove(sourceUrl);
      } else {
        _selected.add(sourceUrl);
      }
    });
  }

  // ===== 单源操作 =====

  Future<void> _openEdit(RssSource source) async {
    await Navigator.of(context).push<RssSource>(
      MaterialPageRoute(builder: (_) => RssSourceEditScreen(source: source)),
    );
    await _load();
  }

  Future<void> _toggleSource(RssSource source) async {
    try {
      final api = ref.read(bookApiProvider);
      if (source.enabled) {
        await api.disableRssSource(source.sourceUrl);
      } else {
        await api.enableRssSource(source.sourceUrl);
      }
      await _load();
    } catch (e) {
      _toast('切换启用状态失败：$e');
    }
  }

  /// 单项菜单（对标原版 rss_source_item.xml：置顶/置底/删除）
  Future<void> _showSourceMenu(RssSource source) async {
    final colorScheme = Theme.of(context).colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 4),
              child: IosGrabber(),
            ),
            ListTile(
              leading: const Icon(Symbols.vertical_align_top_rounded),
              title: const Text('置顶'),
              onTap: () => Navigator.pop(ctx, 'top'),
            ),
            ListTile(
              leading: const Icon(Symbols.vertical_align_bottom_rounded),
              title: const Text('置底'),
              onTap: () => Navigator.pop(ctx, 'bottom'),
            ),
            ListTile(
              leading: Icon(Symbols.delete_rounded, color: colorScheme.error),
              title:
                  Text('删除', style: TextStyle(color: colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'top':
        final index = _sources.indexOf(source);
        if (index > 0) await _reorder(index, 0);
      case 'bottom':
        final index = _sources.indexOf(source);
        if (index >= 0 && index < _sources.length - 1) {
          await _reorder(index, _sources.length - 1);
        }
      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: '删除订阅源',
          content: '确定要删除订阅源「${source.sourceName}」吗？',
          confirmText: '删除',
          isDestructive: true,
        );
        if (confirmed && mounted) {
          try {
            await ref.read(bookApiProvider).deleteRssSource(source.sourceUrl);
            await _load();
          } catch (e) {
            _toast('删除失败：$e');
          }
        }
    }
  }

  /// 拖拽排序（对标原版 RssSourceAdapter itemTouchHelper：
  /// 移动后按序重排 customOrder，仅持久化发生变化的源）；
  /// onReorderItem 的 newIndex 已按移除项调整，无需手动修正
  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final list = List<RssSource>.of(_sources);
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    final changed = <RssSource>[];
    for (var i = 0; i < list.length; i++) {
      if (list[i].customOrder != i) {
        final updated = list[i].copyWith(customOrder: i);
        list[i] = updated;
        changed.add(updated);
      }
    }
    setState(() => _sources = list);
    try {
      final api = ref.read(bookApiProvider);
      for (final s in changed) {
        await api.updateRssSource(s);
      }
    } catch (e) {
      _toast('保存排序失败：$e');
      await _load();
    }
  }

  // ===== 菜单处理 =====

  Future<void> _handleGroupAction(String value) async {
    if (value == 'group_manage') {
      final changed = await showDialog<bool>(
        context: context,
        builder: (_) => RssGroupManageDialog(sources: _sources),
      );
      if (changed == true) await _load();
      return;
    }
    // 再次点击当前过滤词时清除（原版无此行为，iOS 惯例补充）
    if (_keyword.trim() == value) {
      _searchCtrl.clear();
      setState(() => _keyword = '');
      return;
    }
    _setQuery(value);
  }

  Future<void> _handleAction(String action) async {
    switch (action) {
      case 'new':
        await Navigator.of(context).push<RssSource>(
          MaterialPageRoute(builder: (_) => const RssSourceEditScreen()),
        );
        await _load();
      case 'import_file':
        await _importFromFile();
      case 'import_url':
        await _showImportUrlDialog();
      case 'import_qr':
        await _importFromQrCode();
      case 'import_default':
        await _importDefault();
      case 'rule_sub':
        // 对标原版 RssFragment 头部入口 → RuleSubActivity
        await Navigator.of(context).pushNamed(AppRoutes.ruleSub);
      case 'help':
        _showHelpSheet();
    }
  }

  // ===== 批量操作（对标原版 rss_source_sel.xml） =====

  Future<void> _handleBatchAction(String action) async {
    if (_selected.isEmpty) {
      _toast('请先选择订阅源');
      return;
    }
    final api = ref.read(bookApiProvider);
    final selectedSources =
        _sources.where((s) => _selected.contains(s.sourceUrl)).toList();
    switch (action) {
      case 'enable':
      case 'disable':
        final enable = action == 'enable';
        try {
          for (final s in selectedSources) {
            if (s.enabled != enable) {
              if (enable) {
                await api.enableRssSource(s.sourceUrl);
              } else {
                await api.disableRssSource(s.sourceUrl);
              }
            }
          }
          await _load();
          _toast(enable ? '已启用所选订阅源' : '已禁用所选订阅源');
        } catch (e) {
          _toast('操作失败：$e');
        }
      case 'add_group':
        await _showAddGroupDialog();
      case 'remove_group':
        await _showRemoveGroupDialog();
      case 'top':
        await _batchMove(toTop: true);
      case 'bottom':
        await _batchMove(toTop: false);
      case 'export':
        await _exportSelected();
      case 'share':
        await _shareSelected();
      case 'select_range':
        _selectRange();
      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: '删除订阅源',
          content: '确定要删除选中的 ${_selected.length} 个订阅源吗？',
          confirmText: '删除',
          isDestructive: true,
        );
        if (!confirmed || !mounted) return;
        try {
          for (final s in selectedSources) {
            await api.deleteRssSource(s.sourceUrl);
          }
          _exitBatch();
          await _load();
          _toast('已删除所选订阅源');
        } catch (e) {
          _toast('删除失败：$e');
          await _load();
        }
    }
  }

  /// 批量置顶/置底：重排整表 customOrder（对标原版 topSource/bottomSource）
  Future<void> _batchMove({required bool toTop}) async {
    final sel = _sources.where((s) => _selected.contains(s.sourceUrl)).toList();
    final rest =
        _sources.where((s) => !_selected.contains(s.sourceUrl)).toList();
    final list = toTop ? [...sel, ...rest] : [...rest, ...sel];
    final changed = <RssSource>[];
    for (var i = 0; i < list.length; i++) {
      if (list[i].customOrder != i) {
        final updated = list[i].copyWith(customOrder: i);
        list[i] = updated;
        changed.add(updated);
      }
    }
    setState(() => _sources = list);
    try {
      final api = ref.read(bookApiProvider);
      for (final s in changed) {
        await api.updateRssSource(s);
      }
      _toast(toTop ? '已置顶所选订阅源' : '已置底所选订阅源');
    } catch (e) {
      _toast('操作失败：$e');
      await _load();
    }
  }

  /// 添加到分组（对标原版 addGroups：合并进各源 sourceGroup）
  Future<void> _showAddGroupDialog() async {
    final group = await showDialog<String>(
      context: context,
      builder: (_) => const _TextPromptDialog(
        title: '添加到分组',
        hintText: '输入分组名称',
        confirmLabel: '确定',
        autofocus: true,
      ),
    );
    if (group == null || group.trim().isEmpty || !mounted) return;
    final name = group.trim();
    try {
      final api = ref.read(bookApiProvider);
      for (final s in _sources.where((s) => _selected.contains(s.sourceUrl))) {
        final groups = _splitGroups(s.sourceGroup);
        if (groups.contains(name)) continue;
        final merged = [...groups, name].join(',');
        await api.updateRssSource(s.copyWith(sourceGroup: merged));
      }
      await _load();
      _toast('已为所选订阅源添加分组「$name」');
    } catch (e) {
      _toast('添加分组失败：$e');
    }
  }

  /// 移除分组（对标原版 removeGroups：从选中源已有分组中选择）
  Future<void> _showRemoveGroupDialog() async {
    final groups = <String>{};
    for (final s in _sources.where((s) => _selected.contains(s.sourceUrl))) {
      groups.addAll(_splitGroups(s.sourceGroup));
    }
    if (groups.isEmpty) {
      _toast('所选订阅源没有可移除的分组');
      return;
    }
    final group = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('移除分组'),
        children: [
          for (final g in groups.toList()..sort())
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g),
              child: Text(g),
            ),
        ],
      ),
    );
    if (group == null || !mounted) return;
    try {
      final api = ref.read(bookApiProvider);
      for (final s in _sources.where((s) => _selected.contains(s.sourceUrl))) {
        final groups = _splitGroups(s.sourceGroup)..remove(group);
        await api.updateRssSource(
          s.copyWith(sourceGroup: groups.isEmpty ? null : groups.join(',')),
        );
      }
      await _load();
      _toast('已从所选订阅源移除分组「$group」');
    } catch (e) {
      _toast('移除分组失败：$e');
    }
  }

  /// 导出选中（对标原版 exportSelection：JSON 复制到剪贴板）
  Future<void> _exportSelected() async {
    try {
      final selectedSources =
          _sources.where((s) => _selected.contains(s.sourceUrl)).toList();
      final json = const JsonEncoder.withIndent('  ')
          .convert(selectedSources.map((s) => s.toJson()).toList());
      await Clipboard.setData(ClipboardData(text: json));
      _toast('已导出 ${selectedSources.length} 个订阅源到剪贴板');
      _exitBatch();
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  /// 分享源（对标原版 shareSource）
  Future<void> _shareSelected() async {
    try {
      final selectedSources =
          _sources.where((s) => _selected.contains(s.sourceUrl)).toList();
      final json = jsonEncode(selectedSources.map((s) => s.toJson()).toList());
      await Share.share(json, subject: '订阅源分享（${selectedSources.length} 个）');
    } catch (e) {
      _toast('分享失败：$e');
    }
  }

  /// 选择区间（对标原版 checkSelectedInterval：
  /// 选中最小到最大索引之间的全部项）
  void _selectRange() {
    final list = _filtered;
    final indexes = <int>[];
    for (var i = 0; i < list.length; i++) {
      if (_selected.contains(list[i].sourceUrl)) indexes.add(i);
    }
    if (indexes.length < 2) {
      _toast('请先选择两个以上的订阅源');
      return;
    }
    final min = indexes.reduce((a, b) => a < b ? a : b);
    final max = indexes.reduce((a, b) => a > b ? a : b);
    setState(() {
      for (var i = min; i <= max; i++) {
        _selected.add(list[i].sourceUrl);
      }
    });
  }

  // ===== 导入 =====

  /// 解析订阅源文本（JSON 数组或单个对象）
  List<Map<String, dynamic>> _parseSourcesText(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('[')) {
      final decoded = jsonDecode(trimmed);
      if (decoded is! List) throw const FormatException('不是有效的订阅源数组');
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) throw const FormatException('不是有效的订阅源对象');
      return [Map<String, dynamic>.from(decoded)];
    }
    throw const FormatException('格式错误，未解析到订阅源');
  }

  /// 候选订阅源 → 导入确认页（对标原版 comparisonSource 流程）
  Future<void> _parseAndConfirm(String text) async {
    List<Map<String, dynamic>> candidates;
    try {
      candidates = _parseSourcesText(text);
    } catch (e) {
      _toast('格式错误，未解析到订阅源');
      return;
    }
    if (candidates.isEmpty) {
      _toast('格式错误，未解析到订阅源');
      return;
    }
    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RssSourceImportConfirmScreen(
          sources: candidates,
          localSources: _sources,
        ),
      ),
    );
    if (ok == true && mounted) {
      await _load();
      _toast('导入完成');
    }
  }

  /// 本地导入（对标原版 menu_import_local：txt/json 任选，解析层容错）
  Future<void> _importFromFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles();
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.single.path;
      if (path == null) {
        _toast('无法获取文件路径');
        return;
      }
      final text = await File(path).readAsString();
      if (!mounted) return;
      await _parseAndConfirm(text);
    } catch (e) {
      _toast('从文件导入失败：$e');
    }
  }

  /// 网络导入弹窗（对标原版 showImportDialog：URL 输入 + 历史记录）
  Future<void> _showImportUrlDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs
        .getString('rssSourceImportUrls')
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
    await prefs.setString('rssSourceImportUrls', updated.join(','));
    if (!mounted) return;
    await _fetchFromUrl(trimmed);
  }

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
        _toast('获取订阅源失败：HTTP ${response.statusCode}');
        return;
      }
      await _parseAndConfirm(response.body);
    } catch (e) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      _toast('获取订阅源失败：$e');
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
    _toast('扫码内容不是可识别的订阅源数据');
  }

  /// 导入默认规则（对标原版 menu_import_default →
  /// `RssSourceViewModel.importDefault` → `DefaultData.importDefaultRssSources`：
  /// 覆盖 `legado` 分组后灌入 assets 默认源，不经确认对话框）
  Future<void> _importDefault() async {
    try {
      final n = await syncDefaultRssSources(ref.read(bookApiProvider));
      await _load();
      if (!mounted) return;
      _toast(n > 0 ? '已导入 $n 条默认订阅源' : '默认订阅源已同步');
    } catch (e) {
      _toast('导入默认规则失败：$e');
    }
  }

  /// 帮助页（对标原版 showHelp("SourceMRssHelp")）
  void _showHelpSheet() {
    showHelp(context, HelpAssets.sourceMRssHelp);
  }
}

/// 溢出菜单图标行（对标原版菜单项的 icon + title 结构）
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    );
  }
}

/// 网络导入 URL 输入对话框（对标原版 InputDialog：输入框 + 历史记录）
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
      title: const Text('从 URL 导入订阅源'),
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
                hintText: '输入订阅源 URL 地址',
              ),
              keyboardType: TextInputType.url,
            ),
            if (widget.history.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('历史记录',
                  style: Theme.of(context).textTheme.labelMedium),
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
            final text = _controller.text.trim();
            if (text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// 文本输入对话框（分组名称输入，controller 随子树卸载释放）
class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final String confirmLabel;
  final bool autofocus;

  const _TextPromptDialog({
    required this.title,
    required this.hintText,
    required this.confirmLabel,
    this.autofocus = false,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        decoration: InputDecoration(hintText: widget.hintText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
