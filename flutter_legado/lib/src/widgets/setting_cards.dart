import 'package:flutter/material.dart';

/// M3 设置卡（对齐 HapeLee SettingCard M3 分支）
///
/// 规格：圆角 4dp + secondaryContainer 底 + onSecondaryContainer 前景 + 无 elevation。
/// 注意与全局 Card（20dp）区分：小状态标签、设置值徽标用此卡。
class SettingCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const SettingCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: cs.onSecondaryContainer),
        child: child,
      ),
    );
  }
}

/// M3 文本标签卡（对齐 HapeLee TextCard）
///
/// 规格：圆角 8dp + surfaceContainer 底 + labelSmall + 内边距 H8/V4 +
/// 图标 14dp + 间距 4dp + 最多 2 行。
class TextCard extends StatelessWidget {
  final String text;
  final IconData? icon;

  const TextCard({super.key, required this.text, this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// M3 选项卡（对齐 HapeLee OptionCard）
///
/// 规格：圆角 12dp + 固定高 100dp + 图标 32dp（primary）+ labelMedium。
/// 用于底部选项面板（FlowRow 双列）。
class OptionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  const OptionCard({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: selected ? cs.secondaryContainer : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 32,
                color: selected ? cs.onSecondaryContainer : cs.primary),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? cs.onSecondaryContainer
                        : cs.onSurface,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// M3 卡片式 Tab 行（对齐 HapeLee CardTabRow）
///
/// 规格：Row 间距 8dp + 每项 NormalCard（圆角 12dp，内边距 8）；
/// 选中 secondaryContainer/onSecondaryContainer 加粗，
/// 未选中 surfaceContainerLow/onSurfaceVariant；200ms 颜色动画。
class CardTabRow<T> extends StatelessWidget {
  final List<T> tabs;
  final int selectedIndex;
  final String Function(T) labelOf;
  final ValueChanged<int> onSelected;

  const CardTabRow({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.labelOf,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Row(
      children: [
        for (var i = 0; i < tabs.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                  left: i == 0 ? 0 : 4, right: i == tabs.length - 1 ? 0 : 4),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: i == selectedIndex
                      ? cs.secondaryContainer
                      : cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: InkWell(
                  onTap: () => onSelected(i),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Center(
                      child: Text(
                        labelOf(tabs[i]),
                        style: theme.textTheme.labelMediumEmphasized?.copyWith(
                          color: i == selectedIndex
                              ? cs.onSecondaryContainer
                              : cs.onSurfaceVariant,
                          fontWeight: i == selectedIndex
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// M3 labelMedium 强调扩展（HapeLee Emphasized 体系最小集）
///
/// HapeLee 每级字阶配 Medium 版共 30 槽；本地仅需 labelMediumEmphasized，
/// 其余调用处沿用 copyWith(w500) 近似。
extension LabelMediumEmphasized on TextTheme {
  TextStyle? get labelMediumEmphasized =>
      labelMedium?.copyWith(fontWeight: FontWeight.w500);
}
