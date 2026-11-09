// 书架文件夹模式卡片（设置批6a-2）
//
// 对齐参考版 `BookItem.kt:327-657`：
// - `FolderGroupCover`：2×2 封面拼图（最多 4 本；空槽留占位），
//   左下角可叠加书籍数角标（`showBookCount`）；
// - `FolderGroupGridCard`：网格根卡片（封面拼图 + 组名）；
// - `FolderGroupListCard`：列表样式 0 分组 / 1 紧凑列表（封面 + 组名 +
//   书籍数 + 最近阅读）；
// - `FolderGroupHorizontalCard`：列表样式 2 横排 N 张封面。
//
// 封面统一复用 `BookCover`：默认封面 / 仅 WiFi / 阴影 / 文字规则与书架
// 书籍卡片同源，不为组卡片新增网络请求通道。
//
// 编写：全栈工程师（设置批6a-2） ｜ 2026-11-08
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/book.dart';
import '../../models/bookshelf_settings.dart';
import '../../models/misc.dart';
import '../book_cover.dart';
import '../book_grid_item.dart';

/// 组卡片封面拼图（2×2，最多 4 本）
class FolderGroupCover extends StatelessWidget {
  /// 组内预览书籍（调用方已按当前排序取前 N 本）
  final List<Book> previews;

  /// 拼图总宽（高度固定 5:7）
  final double width;

  /// 组自定义封面 URL（非空时优先于书籍拼图，对齐参考 BookGroupCover）
  final String? groupCoverUrl;

  /// 组名（作为组封面缺省图的书名种子，保证同组封面稳定）
  final String? groupName;

  /// 左下角书籍数文本（null = 不显示）
  final String? countText;

  /// 圆角（对齐书架封面 4dp）
  final double borderRadius;

  /// 是否绘制封面阴影（书架独立开关或全局封面阴影）
  final bool coverShadow;

  const FolderGroupCover({
    super.key,
    required this.previews,
    required this.width,
    this.groupCoverUrl,
    this.groupName,
    this.countText,
    this.borderRadius = BookGridItem.coverCornerRadius,
    this.coverShadow = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final height = width * 7 / 5;
    // 2×2 布局：每格 1dp 内边距（参考 BookGroupCover）
    final cellWidth = math.max(1.0, width / 2 - 2);
    final cellHeight = math.max(1.0, height / 2 - 2);
    final content = SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: (groupCoverUrl != null && groupCoverUrl!.isNotEmpty)
                  ? BookCover(
                      coverUrl: groupCoverUrl,
                      width: width,
                      height: height,
                      bookName: groupName,
                    )
                  : ColoredBox(
                      color: colorScheme.surfaceContainerHighest,
                      child: Column(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                _buildSlot(context, 0, cellWidth, cellHeight),
                                _buildSlot(context, 1, cellWidth, cellHeight),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Row(
                              children: [
                                _buildSlot(context, 2, cellWidth, cellHeight),
                                _buildSlot(context, 3, cellWidth, cellHeight),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          if (countText != null && countText!.isNotEmpty)
            Positioned(
              left: 2,
              bottom: 2,
              child: _CountBadge(text: countText!),
            ),
        ],
      ),
    );
    if (!coverShadow) return content;
    return DecoratedBox(
      key: const ValueKey('folderCoverShadow'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: content,
    );
  }

  Widget _buildSlot(
    BuildContext context,
    int index,
    double cellWidth,
    double cellHeight,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: index < previews.length
            ? BookCover(
                coverUrl:
                    previews[index].customCoverUrl ?? previews[index].coverUrl,
                sourceOrigin: previews[index].origin,
                width: cellWidth,
                height: cellHeight,
                bookName: previews[index].name,
                bookAuthor: previews[index].author,
                borderRadius: 2,
                // 组卡片预览只读缓存：未命中显示默认封面，不联网/FFI
                cacheOnly: true,
              )
            : ColoredBox(
                key: ValueKey('folderCoverEmptySlot_$index'),
                // 空槽占位：保持 2×2 拼图尺寸稳定（无书组可见空白格）
                color: colorScheme.surfaceContainerHighest,
              ),
      ),
    );
  }
}

/// 网格根卡片（封面拼图 + 居中组名）
class FolderGroupGridCard extends StatelessWidget {
  final BookGroup group;
  final List<Book> previews;
  final int bookCount;
  final BookshelfSettings settings;
  final double coverWidth;
  final bool coverShadow;

  /// [批9c] 私密分组锁定态：文件夹根不显示预览与书籍数
  final bool locked;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const FolderGroupGridCard({
    super.key,
    required this.group,
    required this.previews,
    required this.bookCount,
    required this.settings,
    required this.coverWidth,
    required this.onTap,
    this.coverShadow = false,
    this.locked = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final countText = settings.showBookCount && !locked ? '$bookCount 本' : null;
    return InkWell(
      key: ValueKey('bookshelf_folder_group_${group.groupId}'),
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(BookGridItem.coverCornerRadius),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          FolderGroupCover(
            previews: previews.take(4).toList(),
            width: coverWidth,
            groupCoverUrl: group.cover,
            groupName: group.groupName,
            countText: countText,
            coverShadow: coverShadow,
          ),
          if (settings.bookshelfGridLayout != 2)
            SizedBox(
              height: BookGridItem.titleAreaHeightFor(
                context,
                maxLines: settings.bookshelfTitleMaxLines,
                smallFont: settings.bookshelfTitleSmallFont,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
                child: Align(
                  alignment: settings.bookshelfTitleCenter
                      ? Alignment.topCenter
                      : Alignment.topLeft,
                  child: Text(
                    group.groupName,
                    maxLines: settings.bookshelfTitleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    textAlign: settings.bookshelfTitleCenter
                        ? TextAlign.center
                        : TextAlign.start,
                    style: TextStyle(
                      fontSize: settings.gridTitleFontSize,
                      height: 1.25,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表样式 0 分组 / 1 紧凑列表的组卡片
///
/// [dense] 为多列窄格模式：封面按格宽 42% 夹取，隐藏「最近阅读」，
/// 组名单行省略，避免 3–5 列时溢出（与书架多列列表同口径）。
class FolderGroupListCard extends StatelessWidget {
  final BookGroup group;
  final List<Book> previews;
  final int bookCount;
  final BookshelfSettings settings;
  final double? maxCoverWidth;
  final bool dense;

  /// 极窄列（4–5 列/格宽 <100dp）竖向紧凑卡：封面在上、组名/计数在下
  final bool vertical;
  final bool coverShadow;

  /// [批9c] 私密分组锁定态：文件夹根不显示预览与书籍数
  final bool locked;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const FolderGroupListCard({
    super.key,
    required this.group,
    required this.previews,
    required this.bookCount,
    required this.settings,
    this.maxCoverWidth,
    this.dense = false,
    this.vertical = false,
    this.coverShadow = false,
    this.locked = false,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final compact =
        settings.bookshelfGroupListStyle == 1 ||
        settings.bookshelfLayoutCompact ||
        dense;
    final configuredCoverWidth = settings.bookshelfListCoverWidth.toDouble();
    final coverWidth = maxCoverWidth == null
        ? configuredCoverWidth
        : math.min(configuredCoverWidth, maxCoverWidth!);
    final cardColorValue = settings.cardColorFor(
      isDark: theme.brightness == Brightness.dark,
    );
    final countText = settings.showBookCount && !locked ? '$bookCount 本' : null;
    final firstBook = previews.isEmpty ? null : previews.first;

    final card = Material(
      key: ValueKey('bookshelf_folder_group_${group.groupId}'),
      color: cardColorValue == 0 ? Colors.transparent : Color(cardColorValue),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: vertical
            ? Padding(
                padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.topCenter,
                      child: FolderGroupCover(
                        previews: previews.take(4).toList(),
                        width: coverWidth,
                        groupCoverUrl: group.cover,
                        groupName: group.groupName,
                        coverShadow: coverShadow,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      group.groupName,
                      key: ValueKey('folderGroupName_${group.groupId}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: settings.bookshelfTitleCenter
                          ? TextAlign.center
                          : TextAlign.start,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.25,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (countText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Align(
                          alignment: settings.bookshelfTitleCenter
                              ? Alignment.center
                              : Alignment.centerLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              countText,
                              key: ValueKey(
                                'folderGroupCount_${group.groupId}',
                              ),
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.25,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              )
            : Padding(
                padding: EdgeInsets.fromLTRB(
                  dense ? 4 : 16,
                  compact ? 6 : 10,
                  dense ? 4 : 16,
                  compact ? 6 : 10,
                ),
                child: Row(
                  crossAxisAlignment: settings.bookshelfListCoverCenter
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    FolderGroupCover(
                      previews: previews.take(4).toList(),
                      width: coverWidth,
                      groupCoverUrl: group.cover,
                      groupName: group.groupName,
                      coverShadow: coverShadow,
                    ),
                    SizedBox(width: dense ? 6 : 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.groupName,
                            maxLines: compact
                                ? 1
                                : settings.bookshelfTitleMaxLines,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.25,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          if (countText != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              countText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (!compact && firstBook != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '最近阅读：${firstBook.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        card,
        if (settings.bookshelfShowDivider && !dense && !vertical)
          Divider(
            height: 0.5,
            thickness: 0.5,
            indent: 16,
            endIndent: 16,
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
      ],
    );
  }
}

/// 列表样式 2：横排 N 张封面
class FolderGroupHorizontalCard extends StatelessWidget {
  final BookGroup group;
  final List<Book> previews;
  final int bookCount;
  final BookshelfSettings settings;
  final bool dense;

  /// [批9c] 私密分组锁定态：文件夹根不显示预览与书籍数
  final bool locked;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 点击某张预览封面（null = 不响应，仅组卡片点击）
  final ValueChanged<Book>? onBookTap;

  const FolderGroupHorizontalCard({
    super.key,
    required this.group,
    required this.previews,
    required this.bookCount,
    required this.settings,
    required this.onTap,
    this.dense = false,
    this.locked = false,
    this.onLongPress,
    this.onBookTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cardColorValue = settings.cardColorFor(
      isDark: theme.brightness == Brightness.dark,
    );
    final coverCount = settings.bookshelfGroupCoverCount.clamp(1, 10);
    final countText = settings.showBookCount && !locked ? '$bookCount 本' : null;

    return Material(
      key: ValueKey('bookshelf_folder_group_${group.groupId}'),
      color: cardColorValue == 0 ? Colors.transparent : Color(cardColorValue),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        group.groupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.25,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (countText != null) ...[
                      const SizedBox(width: 8),
                      // [审查 P2] 书籍数无条件 Flexible + ellipsis：2 列窄
                      // 面板（280–320dp）大字号/千本书名也不横向溢出。
                      Flexible(
                        child: Text(
                          countText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    if (!dense)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, right: 4),
                        child: Icon(
                          Symbols.keyboard_arrow_right_rounded,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              LayoutBuilder(
                builder: (layoutContext, constraints) {
                  // 横排 N 张封面：按卡片可用宽度均分，封面 5:7 定高
                  const spacing = 4.0;
                  final slotWidth = math.max(
                    1.0,
                    (constraints.maxWidth - spacing * (coverCount - 1)) /
                        coverCount,
                  );
                  final slotHeight = slotWidth * 7 / 5;
                  return Row(
                    children: [
                      for (var i = 0; i < coverCount; i++) ...[
                        if (i > 0) const SizedBox(width: spacing),
                        SizedBox(
                          width: slotWidth,
                          height: slotHeight,
                          child: i < previews.length
                              ? GestureDetector(
                                  onTap: onBookTap == null
                                      ? null
                                      : () => onBookTap!(previews[i]),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: BookCover(
                                      coverUrl:
                                          previews[i].customCoverUrl ??
                                          previews[i].coverUrl,
                                      sourceOrigin: previews[i].origin,
                                      width: slotWidth,
                                      height: slotHeight,
                                      bookName: previews[i].name,
                                      bookAuthor: previews[i].author,
                                      cacheOnly: true,
                                    ),
                                  ),
                                )
                              : DecoratedBox(
                                  key: ValueKey('folderHorizontalEmptySlot_$i'),
                                  // 空槽占位：保持横排高度稳定
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书籍数小角标（对齐参考 TextCard 左下角计数）
class _CountBadge extends StatelessWidget {
  final String text;

  const _CountBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          height: 1.5,
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
