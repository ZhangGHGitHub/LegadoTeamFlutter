import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/rss/rss_notifier.dart';
import '../widgets/custom_group_dialog.dart';
import 'source_import_confirm_screen.dart' show AppColorsExt;

/// 订阅源导入状态（对标原版 ImportRssSourceDialog 状态展示）
enum _ImportStatus {
  /// 新增（本地不存在该 sourceUrl）
  isNew,

  /// 更新（本地 lastUpdateTime 较旧）
  isUpdate,

  /// 已有（本地已是最新）
  exists,
}

/// 订阅源导入确认页（对标原版 ImportRssSourceDialog）
///
/// 拉取/解析出的候选订阅源在此页供用户勾选确认后才写入数据库：
/// - 列表项：勾选框 + 源名 + 新增/更新/已有 状态 + 打开（查看 JSON）
/// - 顶部菜单：自定义源分组 / 保留原名 / 保留分组 / 保留启用状态 / 显示源注释
///   （原版 RSS 导入菜单不含「选中新增源/选中更新源」）
/// - 底部：全选|取消全选（n/m）/ 取消 / 确认
class RssSourceImportConfirmScreen extends ConsumerStatefulWidget {
  /// 候选订阅源原始 JSON 列表（保留原始 Map，未入库）
  final List<Map<String, dynamic>> sources;

  /// 本地现有订阅源（用于状态判定与保留选项合并）
  final List<RssSource> localSources;

  const RssSourceImportConfirmScreen({
    super.key,
    required this.sources,
    required this.localSources,
  });

  @override
  ConsumerState<RssSourceImportConfirmScreen> createState() =>
      _RssSourceImportConfirmScreenState();
}

class _RssSourceImportConfirmScreenState
    extends ConsumerState<RssSourceImportConfirmScreen> {
  late final Map<String, RssSource> _localByUrl = {
    for (final s in widget.localSources) s.sourceUrl: s,
  };

  late final List<bool> _selected = [
    // 原版默认选中策略（compareImportedRssSources）：
    // 新增与更新默认选中，已有不选
    for (final s in widget.sources) _statusOf(s) != _ImportStatus.exists,
  ];

  // 菜单选项（对标 import_source.xml：RSS 版含保留启用/源注释）
  bool _keepName = false;
  bool _keepGroup = false;
  bool _keepEnable = false;
  bool _showComment = false;

  // 自定义源分组
  String? _groupName;
  bool _isAddGroup = false;

  bool _importing = false;

  String _urlOf(Map<String, dynamic> raw) =>
      (raw['sourceUrl'] ?? '').toString();

  String _nameOf(Map<String, dynamic> raw) =>
      (raw['sourceName'] ?? '').toString();

  String? _commentOf(Map<String, dynamic> raw) =>
      raw['sourceComment']?.toString();

  int _lastUpdateTimeOf(Map<String, dynamic> raw) =>
      int.tryParse((raw['lastUpdateTime'] ?? '0').toString()) ?? 0;

  _ImportStatus _statusOf(Map<String, dynamic> raw) {
    final local = _localByUrl[_urlOf(raw)];
    if (local == null) return _ImportStatus.isNew;
    if (local.lastUpdateTime < _lastUpdateTimeOf(raw)) {
      return _ImportStatus.isUpdate;
    }
    return _ImportStatus.exists;
  }

  int get _selectCount {
    var count = 0;
    for (final b in _selected) {
      if (b) count++;
    }
    return count;
  }

  bool get _isSelectAll => _selected.every((b) => b);

  /// 确认导入：应用保留选项与自定义分组后写库
  /// （对标 ImportRssSourceViewModel.importSelect）
  ///
  /// 直传选中项的原始 JSON（仅在 raw Map 上覆盖保留/分组字段），
  /// 不经 freezed 类型化往返，由 Rust 侧宽松反序列化兜底
  /// （第三方订阅源非常规字段）。
  Future<void> _confirmImport() async {
    if (_selectCount == 0) return;
    setState(() => _importing = true);
    try {
      final group = _groupName?.trim();
      final toImport = <Map<String, dynamic>>[];
      for (var i = 0; i < widget.sources.length; i++) {
        if (!_selected[i]) continue;
        // 拷贝原始 Map，避免污染预览条目持有的原对象
        final raw = Map<String, dynamic>.from(widget.sources[i]);
        final local = _localByUrl[_urlOf(raw)];
        if (local != null) {
          if (_keepName) {
            raw['sourceName'] = local.sourceName;
          }
          if (_keepGroup) {
            raw['sourceGroup'] = local.sourceGroup;
          }
          if (_keepEnable) {
            raw['enabled'] = local.enabled;
          }
          // 对标原版：customOrder 恒保留本地
          raw['customOrder'] = local.customOrder;
        }
        if (group != null && group.isNotEmpty) {
          if (_isAddGroup) {
            final groups = <String>{
              ...?raw['sourceGroup']
                  ?.toString()
                  .split(',')
                  .map((g) => g.trim())
                  .where((g) => g.isNotEmpty),
              group,
            };
            raw['sourceGroup'] = groups.join(',');
          } else {
            raw['sourceGroup'] = group;
          }
        }
        toImport.add(raw);
      }

      await ref
          .read(bookApiProvider)
          .importRssSources(jsonEncode(toImport));
      await ref.read(rssNotifierProvider.notifier).loadSources();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 自定义源分组弹窗（对标原版 alertCustomGroup：
  /// 添加分组开关 + 分组名称输入）
  Future<void> _showCustomGroupDialog() async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => CustomGroupDialog(
        initialName: _groupName ?? '',
        initialAddGroup: _isAddGroup,
      ),
    );
    if (result == null || !mounted) return;
    final (name, addGroup) = result;
    setState(() {
      _groupName = name.isEmpty ? null : name;
      _isAddGroup = addGroup;
    });
  }

  /// 查看订阅源 JSON（对标原版 tvOpen → CodeDialog）：直接展示原始 JSON
  Future<void> _showSourceJson(Map<String, dynamic> raw) async {
    final json = const JsonEncoder.withIndent('  ').convert(raw);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_nameOf(raw)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('已复制到剪贴板')),
                );
              }
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('导入订阅源'),
        actions: [
          // 自定义源分组（对标 menu_new_group，always 显示）
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: colorScheme.onPrimary,
            ),
            onPressed: _showCustomGroupDialog,
            child: Text(_groupName == null
                ? '自定义源分组'
                : '${_isAddGroup ? '+' : ''}$_groupName'),
          ),
          PopupMenuButton<String>(
            tooltip: '更多选项',
            // 菜单在顶栏下方展开，不覆盖顶栏
            position: PopupMenuPosition.under,
            onSelected: _handleMenu,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'keep_name',
                checked: _keepName,
                child: const Text('保留原名'),
              ),
              CheckedPopupMenuItem(
                value: 'keep_group',
                checked: _keepGroup,
                child: const Text('保留分组'),
              ),
              CheckedPopupMenuItem(
                value: 'keep_enable',
                checked: _keepEnable,
                child: const Text('保留启用状态'),
              ),
              CheckedPopupMenuItem(
                value: 'show_comment',
                checked: _showComment,
                child: const Text('显示源注释'),
              ),
            ],
          ),
        ],
      ),
      body: widget.sources.isEmpty
          ? const Center(child: Text('格式错误，未解析到订阅源'))
          : ListView.separated(
              itemCount: widget.sources.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 16),
              itemBuilder: (context, index) => _buildItem(index),
            ),
      // 底部操作区（对标 dialog_recycler_view：footerLeft / cancel / ok）
      bottomNavigationBar: Container(
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextButton(
                    onPressed: () {
                      final selectAll = _isSelectAll;
                      setState(() {
                        for (var i = 0; i < _selected.length; i++) {
                          _selected[i] = !selectAll;
                        }
                      });
                    },
                    child: Text(
                      _isSelectAll
                          ? '取消全选（$_selectCount/${widget.sources.length}）'
                          : '全选（$_selectCount/${widget.sources.length}）',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _importing
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed:
                      _importing || _selectCount == 0 ? null : _confirmImport,
                  child: _importing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('确认'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleMenu(String value) {
    setState(() {
      switch (value) {
        case 'keep_name':
          _keepName = !_keepName;
        case 'keep_group':
          _keepGroup = !_keepGroup;
        case 'keep_enable':
          _keepEnable = !_keepEnable;
        case 'show_comment':
          _showComment = !_showComment;
      }
    });
  }

  /// 单个候选订阅源项（对标 item_source_import.xml：
  /// 勾选框 + 源名 + 状态标签 + 打开按钮 + 可选源注释）
  Widget _buildItem(int index) {
    final raw = widget.sources[index];
    final status = _statusOf(raw);
    final colorScheme = Theme.of(context).colorScheme;

    final (label, color) = switch (status) {
      _ImportStatus.isNew => ('新增', AppColorsExt.importNew(colorScheme)),
      _ImportStatus.isUpdate =>
        ('更新', AppColorsExt.importUpdate(colorScheme)),
      _ImportStatus.exists =>
        ('已有', colorScheme.onSurfaceVariant),
    };

    return InkWell(
      onTap: () => setState(() => _selected[index] = !_selected[index]),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Checkbox(
              value: _selected[index],
              onChanged: (v) =>
                  setState(() => _selected[index] = v ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _nameOf(raw),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  if (_showComment &&
                      (_commentOf(raw) ?? '').trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _commentOf(raw)!.trim(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                style: TextStyle(fontSize: 13, color: color),
              ),
            ),
            TextButton(
              onPressed: () => _showSourceJson(raw),
              child: const Text('打开'),
            ),
          ],
        ),
      ),
    );
  }
}
