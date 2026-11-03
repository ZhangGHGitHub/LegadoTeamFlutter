// 阅读器九宫格点击区域设置（批4a）
//
// 参考 `ui/book/read/sheet/ClickActionConfigSheet.kt:48-204`：
// 3×3 网格、14 个动作、点格选择动作立即保存；标题「点击区域设置」。
// 本实现用 ModalBottomSheet 承载（高度约屏高 0.58），复用
// ReaderAdvancedConfig 九宫格字段，选择后经 onChanged 由调用方持久化。
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/reader_tap_action.dart';
import 'reader_config_panel.dart';

class ClickActionConfigSheet extends StatefulWidget {
  final ReaderAdvancedConfig config;
  final ValueChanged<ReaderAdvancedConfig> onChanged;

  const ClickActionConfigSheet({
    super.key,
    required this.config,
    required this.onChanged,
  });

  /// 弹出九宫格设置层
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
      builder: (_) => ClickActionConfigSheet(
        config: config,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<ClickActionConfigSheet> createState() => _ClickActionConfigSheetState();
}

class _ClickActionConfigSheetState extends State<ClickActionConfigSheet> {
  late final ReaderAdvancedConfig _working = widget.config.copy();
  int? _editingIndex;

  Future<void> _pickAction(int index) async {
    setState(() => _editingIndex = index);
    final action = await showModalBottomSheet<ReaderTapAction>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final current = _working.tapActionAt(index);
        return SafeArea(
          top: false,
          child: RadioGroup<ReaderTapAction>(
            groupValue: current,
            onChanged: (value) => Navigator.pop(sheetContext, value),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Text(
                    '选择动作',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                for (final option in ReaderTapAction.values)
                  RadioListTile<ReaderTapAction>(
                    key: ValueKey('click-action-option-${option.code}'),
                    value: option,
                    title: Text(option.label),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    setState(() => _editingIndex = null);
    if (action == null) return;
    _working.setTapActionAt(index, action);
    widget.onChanged(_working.copy());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.58;
    return SizedBox(
      key: const ValueKey('click-action-sheet'),
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.touch_app_outlined),
                  const SizedBox(width: 10),
                  Text(
                    '点击区域设置',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                child: Column(
                  children: [
                    for (var row = 0; row < 3; row++)
                      Expanded(
                        child: Row(
                          children: [
                            for (var col = 0; col < 3; col++)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: _buildCell(row * 3 + col),
                                ),
                              ),
                          ],
                        ),
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

  Widget _buildCell(int index) {
    final action = _working.tapActionAt(index);
    final selected = _editingIndex == index;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('click-action-cell-$index'),
        onTap: () => unawaited(_pickAction(index)),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              action.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
