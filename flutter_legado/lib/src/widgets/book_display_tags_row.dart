// 书架展示标签条（批35）：对齐参考版 `BookItem.kt` 的 `TextCard` 小标签
// ——圆角 4、水平内边距 6、垂直 2、secondaryContainer 底 + primary 字，
// 多个标签横向排列、可横向滚动，标签为空时整行不占位。

import 'package:flutter/material.dart';

/// 书架展示标签行（书卡与列表行共用）
class BookDisplayTagsRow extends StatelessWidget {
  final List<String> tags;

  /// 行高（含上下留白）；书卡用紧凑值，列表行略高
  final double height;

  /// 是否紧凑（书卡网格列宽小，字更小）
  final bool compact;

  const BookDisplayTagsRow({
    super.key,
    required this.tags,
    this.height = 20,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final chipStyle = textTheme.labelSmall?.copyWith(
      color: colorScheme.primary,
      fontWeight: FontWeight.w500,
      height: 1.2,
      fontSize: compact ? 10 : 11,
    );
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 标签行本身不参与父级滚动手势竞争（横向独立滚动）
        primary: false,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < tags.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  tags[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: chipStyle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
