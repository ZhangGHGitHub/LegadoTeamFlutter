// 阅读器顶栏按钮配置页（批37）
//
// 对齐参考版入口 `SystemMenuPage`「顶栏按钮」→ `TitleBarActionConfigSheet`
// （FloatingBarIconConfigSheet.kt:47）：列出整个动作池，逐项开关 + 排序 +
// 恢复默认。参考版用拖拽排序（ReorderableConfigList），本批用上下移按钮
// 实现等价能力（更易测试、无拖拽手势冲突）。
//
// 配置只存一份：此处不按书型过滤列表，只在副标题标注适用范围；实际渲染
// 由 `buildReaderTopBarActions` 按当前书型过滤（与参考版
// `isReadMenuActionApplicable` 同口径）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/reader/reader_top_bar_actions_notifier.dart';
import 'reader_top_bar_actions.dart';

/// 顶栏按钮配置底部弹层
class ReaderTopBarConfigSheet extends ConsumerWidget {
  const ReaderTopBarConfigSheet({super.key});

  /// 便捷入口：从阅读设置页打开
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.8,
        child: ReaderTopBarConfigSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(readerTopBarActionsProvider);
    final notifier = ref.read(readerTopBarActionsProvider.notifier);
    final theme = Theme.of(context);
    // 「更多」固定开启并常驻末尾；展示计数时按渲染口径（含它）统计
    final enabledNonMore = config.items.where(
      (e) => e.id != kReaderMoreActionsId && e.enabled,
    );
    final overflow = enabledNonMore.length > kReaderTopBarMaxActions - 1;

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('顶栏按钮', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '选择与排序阅读器顶栏的动作，最多显示 '
                  '$kReaderTopBarMaxActions 个（含固定的「更多」）。'
                  '未显示的动作仍可在「更多」菜单中使用。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (overflow) ...[
                  const SizedBox(height: 4),
                  Text(
                    '已超出上限，末尾动作不会显示在顶栏。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: config.items.length,
              itemBuilder: (context, index) {
                final item = config.items[index];
                final def = readerTopBarActionById[item.id];
                if (def == null) return const SizedBox.shrink();
                return _buildRow(context, notifier, config, item, def);
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                TextButton.icon(
                  key: const ValueKey('reader-topbar-restore'),
                  onPressed: () async {
                    await notifier.restoreDefaults();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('已恢复默认顶栏按钮')));
                  },
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复默认'),
                ),
                const Spacer(),
                Text(
                  '已开启 ${enabledNonMore.length + 1}/$kReaderTopBarMaxActions',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    ReaderTopBarActionsNotifier notifier,
    ReaderTopBarActionsState config,
    ReaderTopBarActionItem item,
    ReaderTopBarActionDef def,
  ) {
    final isMore = item.id == kReaderMoreActionsId;
    final scope = def.scope.scopeLabel;
    final notes = <String>[
      ?scope,
      if (def.supportsLongPress) '支持长按',
      if (isMore) '固定显示',
    ];
    // 「更多」是渲染期固定末位项，不参与排序；其余项只在本区间内移动
    final movable = !isMore;
    // 上下界按去掉「更多」后的可见顺序计算
    final nonMoreIds = [
      for (final e in config.items)
        if (e.id != kReaderMoreActionsId) e.id,
    ];
    final nonMoreIndex = nonMoreIds.indexOf(item.id);
    final canUp = movable && nonMoreIndex > 0;
    final canDown =
        movable && nonMoreIndex >= 0 && nonMoreIndex < nonMoreIds.length - 1;

    return ListTile(
      key: ValueKey('reader-topbar-row-${item.id}'),
      leading: Icon(def.icon),
      title: Text(def.label),
      subtitle: notes.isEmpty ? null : Text(notes.join(' · ')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('reader-topbar-up-${item.id}'),
            tooltip: '上移',
            visualDensity: VisualDensity.compact,
            onPressed: canUp ? () => notifier.move(item.id, -1) : null,
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
          ),
          IconButton(
            key: ValueKey('reader-topbar-down-${item.id}'),
            tooltip: '下移',
            visualDensity: VisualDensity.compact,
            onPressed: canDown ? () => notifier.move(item.id, 1) : null,
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
          ),
          Switch(
            key: ValueKey('reader-topbar-switch-${item.id}'),
            value: item.enabled,
            onChanged: isMore ? null : (_) => notifier.toggle(item.id),
          ),
        ],
      ),
    );
  }
}
