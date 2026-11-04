// 选择菜单配置 Sheet（批4c）
//
// 参考 `TextSelectMenuConfigSheet.kt:67-326`：三组（一级/折叠/隐藏）、
// 组内拖拽/上下移、组间移动、恢复默认、多行展示/展示图标开关、保存/取消。
// 未实现后端项（AI/BGM）不在配置页列出，但模型 JSON 中保留。
//
// 编写：全栈工程师（批4c） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/selection_menu_config.dart';
import '../../screens/reader_config_panel.dart';

class TextSelectMenuConfigSheet extends StatefulWidget {
  final ReaderAdvancedConfig config;
  final ValueChanged<ReaderAdvancedConfig> onChanged;

  const TextSelectMenuConfigSheet({
    super.key,
    required this.config,
    required this.onChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required ReaderAdvancedConfig config,
    required ValueChanged<ReaderAdvancedConfig> onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) =>
          TextSelectMenuConfigSheet(config: config, onChanged: onChanged),
    );
  }

  /// 阅读器内管理按钮入口：保存后落盘并推送共享 Provider
  static Future<void> showForReader(BuildContext context, WidgetRef ref) {
    final cfg = ref.read(readerAdvConfigProvider) ?? ReaderAdvancedConfig();
    return show(
      context,
      config: cfg.copy(),
      onChanged: (updated) {
        final isNight = Theme.of(context).brightness == Brightness.dark;
        unawaited(updated.save(isNight: isNight));
        ref.read(readerAdvConfigProvider.notifier).apply(updated.copy());
      },
    );
  }

  @override
  State<TextSelectMenuConfigSheet> createState() =>
      _TextSelectMenuConfigSheetState();
}

class _TextSelectMenuConfigSheetState extends State<TextSelectMenuConfigSheet> {
  late SelectionMenuConfig _draft = SelectionMenuConfig.decode(
    widget.config.textSelectMenuConfig,
  );
  late bool _expand = widget.config.expandTextMenu;
  late bool _showIcon = widget.config.showSelectMenuIcon;

  List<SelectionMenuConfigItem> _group(int state) => [
    for (final item in _draft.items)
      if (item.showState == state &&
          (selectionMenuDefById(item.id)?.implemented ?? false))
        item,
  ];

  void _moveWithin(
    int state,
    int oldIndex,
    int newIndex, {
    bool adjust = true,
  }) {
    final group = _group(state);
    if (oldIndex < 0 || oldIndex >= group.length) return;
    var target = newIndex;
    if (adjust && target > oldIndex) target -= 1;
    target = target.clamp(0, group.length - 1);
    if (target == oldIndex) return;
    setState(() {
      _draft = _draft.moveWithinGroup(group[oldIndex].id, group[target].id);
    });
  }

  void _moveBy(String id, int delta) {
    setState(() => _draft = _draft.moveBy(id, delta));
  }

  void _moveToState(String id, int state) {
    setState(() => _draft = _draft.moveToState(id, state));
  }

  void _restoreDefaults() {
    // 参考实现没有「恢复默认」入口；本批只恢复菜单顺序/分区，
    // 不重置「多行展示」「展示图标」两个全局开关。
    setState(() => _draft = SelectionMenuConfig.defaults());
  }

  void _confirm() {
    final updated = widget.config.copy()
      ..expandTextMenu = _expand
      ..showSelectMenuIcon = _showIcon
      ..textSelectMenuConfig = _draft.encode();
    widget.onChanged(updated);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = _group(0);
    final collapsed = _group(1);
    final hidden = _group(2);
    return SizedBox(
      key: const ValueKey('select-menu-config-sheet'),
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.format_list_bulleted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '编辑选择菜单',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  0,
                  16,
                  16 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      key: const ValueKey('select-menu-expand-switch'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('多行展示'),
                      value: _expand,
                      onChanged: (v) => setState(() => _expand = v),
                    ),
                    SwitchListTile(
                      key: const ValueKey('select-menu-icon-switch'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('展示图标'),
                      value: _showIcon,
                      onChanged: (v) => setState(() => _showIcon = v),
                    ),
                    _buildGroup('一级菜单', primary, 0),
                    _buildGroup('折叠菜单', collapsed, 1),
                    _buildGroup('已隐藏项目', hidden, 2),
                    const SizedBox(height: 8),
                    // [审查 P3] 320dp/1.3 下三个按钮的最小宽度超出可用
                    // 宽度；窄屏改为 Wrap，避免底部操作行横向溢出。
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final restore = TextButton(
                          key: const ValueKey('select-menu-restore'),
                          onPressed: _restoreDefaults,
                          child: const Text('恢复默认'),
                        );
                        final cancel = TextButton(
                          key: const ValueKey('select-menu-cancel'),
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        );
                        final save = FilledButton(
                          key: const ValueKey('select-menu-save'),
                          onPressed: _confirm,
                          child: const Text('保存'),
                        );
                        if (constraints.maxWidth < 300) {
                          return Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [restore, cancel, save],
                          );
                        }
                        return Row(
                          children: [
                            restore,
                            const Spacer(),
                            cancel,
                            const SizedBox(width: 8),
                            save,
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroup(
    String title,
    List<SelectionMenuConfigItem> items,
    int state,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '$title（${items.length}）',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '暂无',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ReorderableListView.builder(
              key: ValueKey('select-menu-group-$state'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: items.length,
              onReorderItem: (oldIndex, newIndex) =>
                  _moveWithin(state, oldIndex, newIndex, adjust: false),
              itemBuilder: (context, index) {
                final item = items[index];
                final def = selectionMenuDefById(item.id)!;
                return _buildItemRow(
                  key: ValueKey('select-menu-item-${item.id}'),
                  def: def,
                  index: index,
                  state: state,
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildItemRow({
    required Key key,
    required SelectionMenuItemDef def,
    required int index,
    required int state,
  }) {
    // [审查 P3] 320dp/1.3 下默认 48dp 三连按钮会横向溢出；
    // 收紧到 32dp 让标题用 Flexible 省略，保证窄屏无 RenderFlex 溢出。
    final compact = IconButton.styleFrom(
      minimumSize: const Size(32, 32),
      maximumSize: const Size(32, 32),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return ListTile(
      key: key,
      dense: true,
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 24,
      horizontalTitleGap: 8,
      leading: ReorderableDragStartListener(
        index: index,
        child: const Icon(Icons.drag_handle, size: 20),
      ),
      title: Row(
        children: [
          if (_showIcon) ...[
            Icon(def.icon, size: 18),
            const SizedBox(width: 8),
          ],
          Flexible(child: Text(def.label, overflow: TextOverflow.ellipsis)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('select-menu-up-${def.id}'),
            tooltip: '上移',
            style: compact,
            iconSize: 18,
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: () => _moveBy(def.id, -1),
          ),
          IconButton(
            key: ValueKey('select-menu-down-${def.id}'),
            tooltip: '下移',
            style: compact,
            iconSize: 18,
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: () => _moveBy(def.id, 1),
          ),
          PopupMenuButton<int>(
            key: ValueKey('select-menu-move-${def.id}'),
            tooltip: '移动到',
            style: compact,
            iconSize: 18,
            icon: const Icon(Icons.swap_horiz),
            onSelected: (value) => _moveToState(def.id, value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('移至一级')),
              PopupMenuItem(value: 1, child: Text('移至折叠')),
              PopupMenuItem(value: 2, child: Text('移至隐藏')),
            ],
          ),
        ],
      ),
    );
  }
}
