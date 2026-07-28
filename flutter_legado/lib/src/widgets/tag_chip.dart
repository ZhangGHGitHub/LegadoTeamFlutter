import 'package:flutter/material.dart';

/// 标签组件 — 可点击/可删除的标签
class TagChip extends StatelessWidget {
  final String label;
  final Color? color;
  final VoidCallback? onDeleted;
  final VoidCallback? onTap;

  const TagChip({
    super.key,
    required this.label,
    this.color,
    this.onDeleted,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bgColor = color ?? colorScheme.secondaryContainer;
    final fgColor = color != null
        ? colorScheme.onPrimary
        : colorScheme.onSecondaryContainer;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: fgColor,
                ),
              ),
              if (onDeleted != null) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: onDeleted,
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: fgColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
