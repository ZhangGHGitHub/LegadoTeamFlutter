// 书架展示标签条（批35）：对齐参考版 `BookItem.kt` 的 `TextCard` 小标签
// ——圆角 4、水平内边距 6、垂直 2、secondaryContainer 底 + primary 字，
// 多个标签横向排列、可横向滚动，标签为空时整行不占位。

import 'package:flutter/material.dart';

/// 书架展示标签行（书卡与列表行共用）
class BookDisplayTagsRow extends StatelessWidget {
  final List<String> tags;

  /// 行高下限（含上下留白）；书卡用紧凑值，列表行略高
  ///
  /// [批35b P3-4] 固定高度在大字号/无障碍缩放下会裁切文字：实际渲染高度取
  /// `max(height, 按 textScaler 计算的内容高)`，见 [heightFor]。
  final double height;

  /// 是否紧凑（书卡网格列宽小，字更小）
  final bool compact;

  const BookDisplayTagsRow({
    super.key,
    required this.tags,
    this.height = 20,
    this.compact = false,
  });

  /// 按当前系统文字缩放计算标签行所需高度（[批35b P3-4]）
  ///
  /// 内容高 = 缩放后字号 × 行高系数 1.2 + 上下内边距 2×2；默认字号下
  /// （缩放 1.0）紧凑卡为 16dp、列表为 17.2dp，均低于 [minHeight]（设计
  /// 固定行高 20dp），故保持原视觉；大字号时按实际内容抬升，不裁切。
  ///
  /// 父级（网格 cell 高宽比）必须使用同一函数换算预留高度，否则
  /// `Expanded` 封面会被标签行挤压。
  static double heightFor(
    BuildContext context, {
    bool compact = false,
    double minHeight = 20,
  }) {
    final fontSize = compact ? 10.0 : 11.0;
    final needed = MediaQuery.textScalerOf(context).scale(fontSize) * 1.2 + 4;
    return needed > minHeight ? needed : minHeight;
  }

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
    final effectiveHeight = heightFor(context, compact: compact, minHeight: height);
    return SizedBox(
      height: effectiveHeight,
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
