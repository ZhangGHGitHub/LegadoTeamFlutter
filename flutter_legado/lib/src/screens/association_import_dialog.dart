import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../models/models.dart';
import '../providers/association/association_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../services/source_import_service.dart';
import '../widgets/custom_group_dialog.dart';

/// 关联导入弹出式确认对话框（对标原版各 ImportXxxDialog，视觉遵循 MD3）
///
/// 原版经 showDialogFragment 在当前页面之上弹出确认框（dialog_recycler_view）：
/// - 头部：标题 + 自定义源分组 / ⋮ 菜单（bookSource）
/// - 主体：逐条勾选确认（新增/更新/已存在状态标签 + 打开查看 JSON）
/// - 底部：全选（n/m）| 取消 | 确认（n），导入完成后关闭对话框
Future<void> showAssociationImportDialog(
  BuildContext context, {
  String? url,
  ImportType? type,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => AssociationImportDialog(url: url, type: type),
  );
}

class AssociationImportDialog extends ConsumerStatefulWidget {
  const AssociationImportDialog({super.key, this.url, this.type});

  /// 预填内容地址（非空时打开即自动拉取解析）
  final String? url;

  /// 深度链接指定的类型提示
  final ImportType? type;

  @override
  ConsumerState<AssociationImportDialog> createState() =>
      _AssociationImportDialogState();
}

class _AssociationImportDialogState
    extends ConsumerState<AssociationImportDialog> {
  final _urlController = TextEditingController();

  /// 最近一次加载动作（错误态重试复用）
  Future<void> Function()? _lastLoad;

  // ===== 选择状态（对应原版 selectStatus）=====
  List<bool> _selected = [];
  AssociationState? _selectionFor;

  // bookSource / replaceRule 菜单选项（对应 import_source.xml / import_replace.xml）
  bool _keepName = false;
  bool _keepGroup = false;
  bool _keepEnable = false;
  bool _showComment = false;
  String? _groupName;
  bool _isAddGroup = false;

  /// bookSource 本地快照（保留选项覆盖用；获取失败按空处理）
  Map<String, BookSource>? _localBookSources;

  /// TXT 目录规则 example 展开状态（对应原版 maxLines 3↔39）
  final Set<int> _exampleExpanded = {};

  bool _importing = false;

  @override
  void initState() {
    super.initState();
    final url = widget.url;
    if (url != null && url.isNotEmpty) {
      _urlController.text = url;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(associationNotifierProvider.notifier).bootstrapFromDeepLink(
              type: widget.type,
              srcUrl: url,
            );
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// 选择状态与条目列表同步（原版默认：新增/更新选中，已存在不选；none 全选）
  ///
  /// 注意：必须以 state 对象为基准判定（freezed 的 items getter 每次访问
  /// 都会新建 EqualUnmodifiableListView 包装，按列表 identity 比较永远不等，
  /// 会导致每次重建都重置勾选、点选即回弹）
  void _syncSelection(AssociationState state) {
    if (identical(_selectionFor, state)) return;
    _selectionFor = state;
    _selected = [
      for (final item in state.items) item.status != ImportItemStatus.exists,
    ];
  }

  int get _selectCount => _selected.where((b) => b).length;

  bool get _isSelectAll => _selected.isNotEmpty && _selected.every((b) => b);

  // ===== 加载动作 =====

  Future<void> _loadFromInput() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入内容地址')),
      );
      return;
    }
    final notifier = ref.read(associationNotifierProvider.notifier);
    _lastLoad = () => notifier.loadFromUrl(url);
    await _lastLoad!();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择导入文件',
      type: FileType.any,
      allowedExtensions: ['json', 'txt'],
    );
    if (result == null || result.paths.isEmpty) return;
    final path = result.paths.first;
    if (path == null) return;
    final notifier = ref.read(associationNotifierProvider.notifier);
    _lastLoad = () => notifier.loadFromFile(path);
    await _lastLoad!();
  }

  Future<void> _loadFromClipboard() async {
    final notifier = ref.read(associationNotifierProvider.notifier);
    _lastLoad = notifier.loadFromClipboard;
    await _lastLoad!();
  }

  // ===== 菜单（对应原版各对话框 toolbar menu）=====

  /// 自定义分组弹窗（对应原版 alertCustomGroup：添加分组开关 + 分组名输入）
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

  void _handleMenu(String value) {
    setState(() {
      switch (value) {
        case 'select_new':
          final indices = _indicesOfStatus(ImportItemStatus.isNew);
          final allSelected =
              indices.isNotEmpty && indices.every((i) => _selected[i]);
          for (final i in indices) {
            _selected[i] = !allSelected;
          }
        case 'select_update':
          final indices = _indicesOfStatus(ImportItemStatus.isUpdate);
          final allSelected =
              indices.isNotEmpty && indices.every((i) => _selected[i]);
          for (final i in indices) {
            _selected[i] = !allSelected;
          }
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

  List<int> _indicesOfStatus(ImportItemStatus status) {
    final state = ref.read(associationNotifierProvider);
    return [
      for (var i = 0; i < state.items.length; i++)
        if (state.items[i].status == status) i,
    ];
  }

  // ===== 查看 JSON（对应原版 tvOpen → CodeDialog）=====

  Future<void> _showItemJson(AssociationItem item) async {
    final json = const JsonEncoder.withIndent('  ').convert(item.raw);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.name),
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

  // ===== 确认导入（对应原版各 importSelect）=====

  Future<void> _confirmImport(AssociationState state) async {
    if (_selectCount == 0 || _importing) return;
    setState(() => _importing = true);
    try {
      final type = state.type;
      final items = <Map<String, dynamic>>[];
      if (type == ImportType.bookSource) {
        await _ensureLocalBookSources();
        for (var i = 0; i < state.items.length; i++) {
          if (!_selected[i]) continue;
          final raw = Map<String, dynamic>.from(state.items[i].raw);
          // 保留选项覆盖（对标 ImportBookSourceViewModel.importSelect）
          final url = raw['bookSourceUrl']?.toString() ?? '';
          final local = _localBookSources?[url];
          if (local != null) {
            if (_keepName) {
              raw['bookSourceName'] = local.bookSourceName;
            }
            if (_keepGroup) {
              raw['bookSourceGroup'] = local.bookSourceGroup;
            }
            if (_keepEnable) {
              raw['enabled'] = local.enabled;
              raw['enabledExplore'] = local.enabledExplore;
            }
          }
          items.add(_applyGroupOverride(raw, field: 'bookSourceGroup'));
        }
      } else if (type == ImportType.replaceRule) {
        // 替换规则仅应用分组覆盖（对标 ImportReplaceRuleViewModel.importSelect）
        for (var i = 0; i < state.items.length; i++) {
          if (!_selected[i]) continue;
          items.add(
            _applyGroupOverride(
              Map<String, dynamic>.from(state.items[i].raw),
              field: 'group',
            ),
          );
        }
      } else {
        for (var i = 0; i < state.items.length; i++) {
          if (!_selected[i]) continue;
          items.add(Map<String, dynamic>.from(state.items[i].raw));
        }
      }

      final result = await ref
          .read(associationNotifierProvider.notifier)
          .confirmImport(type, items);
      if (!mounted) return;
      _showResultDialog(result);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// bookSource 本地快照（保留选项覆盖需要；获取失败按空处理）
  Future<void> _ensureLocalBookSources() async {
    if (_localBookSources != null) return;
    try {
      final list = await ref.read(bookApiProvider).getBookSources();
      _localBookSources = {for (final s in list) s.bookSourceUrl: s};
    } catch (_) {
      _localBookSources = const {};
    }
  }

  /// 自定义分组覆盖（对应原版 importSelect 的 group/isAddGroup 逻辑）
  Map<String, dynamic> _applyGroupOverride(
    Map<String, dynamic> raw, {
    required String field,
  }) {
    final group = _groupName?.trim();
    if (group == null || group.isEmpty) return raw;
    final out = Map<String, dynamic>.from(raw);
    if (_isAddGroup) {
      final groups = <String>{
        ...?out[field]
            ?.toString()
            .split(',')
            .map((g) => g.trim())
            .where((g) => g.isNotEmpty),
        group,
      };
      out[field] = groups.join(',');
    } else {
      out[field] = group;
    }
    return out;
  }

  /// 导入结果对话框（对应原版 finallyDialog）：确认后关闭本对话框
  void _showResultDialog(ImportResult result) {
    final contentChildren = <Widget>[
      Text(result.summary),
      if (result.errors.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final e in result.errors)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '• $e',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入完成'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: contentChildren)),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    ).then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(associationNotifierProvider);
    _syncSelection(state);
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final hairline = colorScheme.outlineVariant.withValues(alpha: 0.6);

    return Dialog(
      // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
      backgroundColor: colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        // 宽近全宽（对齐原版 MATCH_PARENT），桌面端限宽；高不超过 85% 屏高
        constraints: BoxConstraints(
          maxWidth: min(size.width - 48, 640),
          maxHeight: size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(state, colorScheme),
            Divider(height: 1, thickness: 0.5, color: hairline),
            Flexible(
              child: switch (state.phase) {
                AssociationPhase.idle => _buildIdle(),
                AssociationPhase.loading => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                AssociationPhase.error => _buildError(state.error!),
                AssociationPhase.ready => ListView.separated(
                    shrinkWrap: true,
                    // [LAYOUT_PLAN P3] 列表纵向留白 8dp；行 horizontal8 见 _buildItem
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: state.items.length,
                    separatorBuilder: (_, _) => Divider(
                        height: 1,
                        indent: 16,
                        thickness: 0.5,
                        color: hairline),
                    itemBuilder: (context, index) =>
                        _buildItem(state, index),
                  ),
              },
            ),
            if (state.phase == AssociationPhase.ready) ...[
              Divider(height: 1, thickness: 0.5, color: hairline),
              _buildFooter(state),
            ],
          ],
        ),
      ),
    );
  }

  /// 头部（对应原版 toolbar：标题 + 自定义源分组 + ⋮ 菜单；扫码/重置为本轨手动入口）
  Widget _buildHeader(AssociationState state, ColorScheme colorScheme) {
    return Padding(
      // [LAYOUT_PLAN P3] Dialog 内水平边距统一 16dp（全局标尺，右 8 留给动作区）
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              state.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          // 自定义分组（bookSource / replaceRule，对标原版 menu_new_group）
          if (state.phase == AssociationPhase.ready &&
              (state.type == ImportType.bookSource ||
                  state.type == ImportType.replaceRule))
            TextButton(
              onPressed: _showCustomGroupDialog,
              child: Text(_groupName == null
                  ? '自定义分组'
                  : '${_isAddGroup ? '+' : ''}$_groupName'),
            ),
          // bookSource 更多选项（对标 import_source.xml）
          if (state.phase == AssociationPhase.ready &&
              state.type == ImportType.bookSource)
            PopupMenuButton<String>(
              tooltip: '更多选项',
              // [LAYOUT_PLAN P3] 菜单在顶栏下方展开，不覆盖顶栏（对齐 P2 规范）
              position: PopupMenuPosition.under,
              onSelected: _handleMenu,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'select_new',
                  child: Text('选中新增源'),
                ),
                const PopupMenuItem(
                  value: 'select_update',
                  child: Text('选中更新源'),
                ),
                const PopupMenuDivider(),
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
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            tooltip: '重置',
            onPressed: () {
              _urlController.clear();
              _exampleExpanded.clear();
              ref.read(associationNotifierProvider.notifier).reset();
            },
          ),
        ],
      ),
    );
  }

  /// 空闲态：输入内容地址 + 文件 / 剪贴板入口（类型由内容自动识别）
  Widget _buildIdle() {
    return SingleChildScrollView(
      // [LAYOUT_PLAN P3] Dialog 内水平边距统一 16dp（全局标尺）
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Symbols.link_rounded),
              labelText: '内容地址',
              hintText: 'https://example.com/sources.json',
              // 扫码导入（对应原版管理页扫码入口；本轨手动路径保留）
              suffixIcon: IconButton(
                icon: const Icon(Symbols.qr_code_scanner_rounded),
                tooltip: '扫码导入',
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  // [fix Task#24 | 2026-08-08] 去掉 <String> 泛型，避免 routes 表
                  // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
                  final raw = await navigator.pushNamed(AppRoutes.qrcode);
                  final result = raw is String ? raw : null;
                  if (result != null && result.isNotEmpty) {
                    _urlController.text = result;
                    await _loadFromInput();
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Symbols.folder_open_rounded),
                  label: const Text('从文件'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loadFromClipboard,
                  icon: const Icon(Symbols.content_paste_rounded),
                  label: const Text('从剪贴板'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loadFromInput,
              child: const Text('加载'),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '导入类型由内容格式自动识别：书源 / RSS 源 / 替换规则 / 主题配置 / HTTP TTS / 字典规则 / TXT 目录规则',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 错误态（对应原版 tvMsg）
  Widget _buildError(String message) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 24),
            FilledButton.tonal(
              onPressed: _lastLoad != null ? () => _lastLoad!() : null,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 单条候选项（对标 item_source_import.xml：勾选框 + 名称(分组) + 状态标签 + 注释 + 打开）
  Widget _buildItem(AssociationState state, int index) {
    final item = state.items[index];
    final colorScheme = Theme.of(context).colorScheme;

    // 状态色取 colorScheme 角色（M3 token）：新增 tertiary / 更新 secondary / 已存在 onSurfaceVariant
    final (label, color) = switch (item.status) {
      ImportItemStatus.isNew => ('新增', colorScheme.tertiary),
      ImportItemStatus.isUpdate => ('更新', colorScheme.secondary),
      ImportItemStatus.exists => ('已存在', colorScheme.onSurfaceVariant),
      ImportItemStatus.none => ('', Colors.transparent),
    };

    final title = item.group != null
        ? '${item.name}(${item.group})'
        : item.name;

    // 注释：bookSource/rss 由菜单开关控制；txtTocRule 的 example 常显且可点按展开
    final showComment =
        state.type == ImportType.txtTocRule || _showComment;
    final comment = item.comment;

    return InkWell(
      onTap: () => setState(() => _selected[index] = !_selected[index]),
      child: Padding(
        // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8（全局行规范）
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
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
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  if (showComment && comment != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: GestureDetector(
                        // txtTocRule：点按展开/收起（对应原版 maxLines 3↔39）
                        onTap: state.type == ImportType.txtTocRule
                            ? () => setState(() {
                                if (_exampleExpanded.contains(index)) {
                                  _exampleExpanded.remove(index);
                                } else {
                                  _exampleExpanded.add(index);
                                }
                              })
                            : null,
                        child: Text(
                          comment,
                          maxLines: state.type == ImportType.txtTocRule &&
                                  _exampleExpanded.contains(index)
                              ? 39
                              : 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (label != '')
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: color),
                ),
              ),
            TextButton(
              onPressed: () => _showItemJson(item),
              child: const Text('打开'),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部操作区（对标 dialog_recycler_view：footerLeft / cancel / ok）
  Widget _buildFooter(AssociationState state) {
    return Padding(
      // [LAYOUT_PLAN P3] 底部操作区水平边距 16dp（全局标尺）
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 16),
      child: Row(
        children: [
          // 全选可压缩（计数大时如「全选（419/947）」仍不溢出）
          Flexible(
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
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
                    ? '取消全选（$_selectCount/${state.items.length}）'
                    : '全选（$_selectCount/${state.items.length}）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
            onPressed:
                _importing ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed:
                _importing || _selectCount == 0
                    ? null
                    : () => _confirmImport(state),
            child: _importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('确认（$_selectCount）'),
          ),
        ],
      ),
    );
  }
}
