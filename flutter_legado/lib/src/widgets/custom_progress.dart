import 'package:flutter/material.dart';

/// 自定义进度条 — 带标签的进度条
class CustomProgress extends StatelessWidget {
  final double value; // 0.0 - 1.0
  final Color? color;
  final double height;
  final bool showLabel;

  const CustomProgress({
    super.key,
    required this.value,
    this.color,
    this.height = 6,
    this.showLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progressColor = color ?? colorScheme.primary;
    final clampedValue = value.clamp(0.0, 1.0);

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(height / 2),
            child: SizedBox(
              height: height,
              child: LinearProgressIndicator(
                value: clampedValue,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              ),
            ),
          ),
        ),
        if (showLabel) ...[
          const SizedBox(width: 8),
          Text(
            '${(clampedValue * 100).toInt()}%',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }
}
