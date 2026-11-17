import 'package:flutter/material.dart';

/// 徽标组件 — 右上角数字徽标
class BadgeWidget extends StatelessWidget {
  final Widget child;
  final int count;
  final Color? color;
  final bool showZero;

  const BadgeWidget({
    super.key,
    required this.child,
    this.count = 0,
    this.color,
    this.showZero = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final badgeColor = color ?? colorScheme.error;
    final showBadge = count > 0 || showZero;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (showBadge)
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: colorScheme.surface, width: 1.5),
              ),
              child: Text(
                count > 99 ? '99+' : '$count',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onError,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
