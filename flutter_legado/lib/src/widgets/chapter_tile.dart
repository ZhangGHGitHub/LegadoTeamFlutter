import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 章节列表项 — 支持已读/当前状态高亮
class ChapterTile extends StatelessWidget {
  final String title;
  final bool isRead;
  final bool isCurrent;
  final VoidCallback? onTap;

  const ChapterTile({
    super.key,
    required this.title,
    this.isRead = false,
    this.isCurrent = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Color textColor;
    if (isCurrent) {
      textColor = colorScheme.primary;
    } else if (isRead) {
      textColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.6);
    } else {
      textColor = colorScheme.onSurface;
    }

    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: textColor,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isCurrent
          ? Icon(Symbols.play_arrow_rounded, color: colorScheme.primary, size: 20)
          : null,
      selected: isCurrent,
      selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
      onTap: onTap,
    );
  }
}
