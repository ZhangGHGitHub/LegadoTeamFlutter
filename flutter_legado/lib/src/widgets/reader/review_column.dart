import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 段末评论角标（对齐原版 [ReviewColumn]）
///
/// Apple 风格：轻量气泡 + 数字，仅 count > 0 时展示。
/// — Bridge/UI · Auto ｜ 2026-08-13
class ReviewColumnBadge extends StatelessWidget {
  final int count;
  final VoidCallback? onTap;

  const ReviewColumnBadge({
    super.key,
    required this.count,
    this.onTap,
  });

  String get _label {
    if (count >= 1000) return '999+';
    return '$count';
  }

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CupertinoColors.systemBlue.resolveFrom(context);
    final bg = isDark
        ? accent.withValues(alpha: 0.22)
        : accent.withValues(alpha: 0.12);
    final fg = isDark ? Colors.white : accent;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Container(
          constraints: const BoxConstraints(minWidth: 22, minHeight: 18),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Text(
            _label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: fg,
              height: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
