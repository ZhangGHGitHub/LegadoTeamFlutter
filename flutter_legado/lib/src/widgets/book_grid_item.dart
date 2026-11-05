import 'package:flutter/material.dart';

import 'book_cover.dart';
import 'book_display_tags_row.dart';

/// 书架网格项（对齐参考版 `BookItem.kt` BookshelfGridItem）
///
/// 结构（设置批6a-1）：
/// - 封面圆角 4dp（参考当前口径），阴影默认关（`bookshelfCoverShadow`）
/// - 网格样式：0 标准（封面下书名）/ 1 紧凑（书名叠封面渐变）/
///   2 仅封面
/// - 书名：字号 11/12（小字体开关）、居中/左对齐、最大行数 1–5
/// - 右上未读角标、右下新章节圆点、封面左下书籍类型、底部阅读进度条
/// - 我方扩展（批35）：封面下展示标签行
///
/// 长按分区保持既有一比一语义：封面 → 书籍信息，标题 → 操作菜单。
class BookGridItem extends StatelessWidget {
  /// 标签行高度下限（父级网格计算 cell 高宽比时须同步使用）
  static const double tagRowHeight = 20;

  /// 封面圆角（参考版 BookshelfItemCover RoundedCornerShape(4.dp)）
  static const double coverCornerRadius = 4;

  final String title;
  final String? coverUrl;

  /// 书源 origin（封面 coverDecodeJs）
  final String? sourceOrigin;

  /// Hero 过渡标签（书架↔详情，约定 `book-cover:<book url>`）
  final String? heroTag;

  /// 未读章节数（>0 时显示右上角角标；调用方按 showUnread 传 0 关闭）
  final int unreadNum;

  /// 阅读进度（null 表示无阅读记录，不显示进度条）
  final double? progress;

  /// 点击回调
  final VoidCallback? onTap;

  /// 封面区域长按回调（打开书籍信息页）
  final VoidCallback? onCoverLongPress;

  /// 标题区域长按回调（打开操作菜单）
  final VoidCallback? onInfoLongPress;

  /// [批35] 展示标签（用户标签/书源分类/字数，空列表不渲染）
  final List<String> tags;

  /// [批35] 父级网格是否已按标签行预留高度
  final bool reserveTagRow;

  /// 网格样式：0 标准 / 1 紧凑 / 2 仅封面
  final int gridStyle;

  /// 书名小字体（11sp，否则 12sp）
  final bool titleSmallFont;

  /// 书名居中（false = 左对齐）
  final bool titleCenter;

  /// 书名最大行数（仅标准样式；紧凑样式固定 2 行）
  final int titleMaxLines;

  /// 封面阴影（默认关，参考当前口径）
  final bool coverShadow;

  /// 新章节圆点（`showUnreadNew && book.lastCheckCount > 0`）
  final bool showNewBadge;

  /// 书籍类型标签（`showTip` 开启时的「音频/漫画/本地/文件/小说」）
  final String? typeLabel;

  /// 卡片背景色（0 = 跟随主题；由调用方按日夜解析）
  final int cardColor;

  const BookGridItem({
    super.key,
    required this.title,
    this.coverUrl,
    this.sourceOrigin,
    this.heroTag,
    this.unreadNum = 0,
    this.progress,
    this.tags = const [],
    this.reserveTagRow = false,
    this.gridStyle = 0,
    this.titleSmallFont = false,
    this.titleCenter = true,
    this.titleMaxLines = 2,
    this.coverShadow = false,
    this.showNewBadge = false,
    this.typeLabel,
    this.cardColor = 0,
    this.onTap,
    this.onCoverLongPress,
    this.onInfoLongPress,
  });

  /// 标准样式书名区高度（父级网格 cell aspect 计算必须调用同一函数）
  static double titleAreaHeightFor(
    BuildContext context, {
    int maxLines = 2,
    bool smallFont = false,
  }) {
    final fontSize = smallFont ? 11.0 : 12.0;
    final scaled = MediaQuery.textScalerOf(context).scale(fontSize);
    // 行高 1.25 + 上 6 / 下 4 内边距（与下方 _buildTitleArea 同式）
    return scaled * 1.25 * maxLines + 10;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveTagRowHeight = BookDisplayTagsRow.heightFor(
      context,
      compact: true,
      minHeight: tagRowHeight,
    );
    final showTitleBelow = gridStyle == 0;
    final showTags = gridStyle != 2 && tags.isNotEmpty;
    final reserveTags = gridStyle != 2 && reserveTagRow;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            onLongPress: onCoverLongPress,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(coverCornerRadius),
                boxShadow: coverShadow
                    ? [
                        BoxShadow(
                          color:
                              colorScheme.shadow.withValues(alpha: 0.18),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(coverCornerRadius),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        BookCover(
                          coverUrl: coverUrl,
                          width: constraints.maxWidth.isFinite
                              ? constraints.maxWidth
                              : 80,
                          height: constraints.maxHeight.isFinite
                              ? constraints.maxHeight
                              : 110,
                          borderRadius: 0,
                          sourceOrigin: sourceOrigin,
                          heroTag: heroTag,
                        ),
                        // 紧凑样式：书名叠在封面底部渐变上
                        if (gridStyle == 1)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0xB3000000),
                                  ],
                                ),
                              ),
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: titleCenter
                                    ? TextAlign.center
                                    : TextAlign.start,
                                style: TextStyle(
                                  fontSize:
                                      titleSmallFont ? 11 : 12,
                                  color: Colors.white,
                                  height: 1.25,
                                  shadows: const [
                                    Shadow(
                                      color: Color(0x80000000),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        // 未读角标（右上）
                        if (unreadNum > 0)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              constraints: const BoxConstraints(
                                  minWidth: 18, minHeight: 18),
                              decoration: BoxDecoration(
                                color: colorScheme.error,
                                borderRadius: const BorderRadius.only(
                                  topRight: Radius.circular(6),
                                  bottomLeft: Radius.circular(8),
                                ),
                              ),
                              child: Text(
                                unreadNum > 99 ? '99+' : '$unreadNum',
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
                        // 新章节圆点（右下，避开右上未读角标）
                        if (showNewBadge)
                          Positioned(
                            key: ValueKey<String>(
                                'bookshelf-new-dot-$title'),
                            right: 5,
                            bottom: 6,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: colorScheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: colorScheme.surface,
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        // 书籍类型（左下；紧凑样式让位给封面书名，改左上）
                        if (typeLabel != null && typeLabel!.isNotEmpty)
                          Positioned(
                            left: 4,
                            top: gridStyle == 1 ? 4 : null,
                            bottom: gridStyle == 1 ? null : 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0x99000000),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                typeLabel!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ),
                        // 封面底部阅读进度条（2dp）
                        if (progress != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: progress!.clamp(0.0, 1.0),
                              minHeight: 2,
                              backgroundColor: colorScheme.primary
                                  .withValues(alpha: 0.25),
                              valueColor: AlwaysStoppedAnimation(
                                  colorScheme.primary),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        if (showTitleBelow)
          GestureDetector(
            onTap: onTap,
            onLongPress: onInfoLongPress,
            child: SizedBox(
              height: titleAreaHeightFor(
                context,
                maxLines: titleMaxLines,
                smallFont: titleSmallFont,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
                child: Align(
                  alignment: titleCenter
                      ? Alignment.topCenter
                      : Alignment.topLeft,
                  child: Text(
                    title,
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    textAlign:
                        titleCenter ? TextAlign.center : TextAlign.start,
                    style: TextStyle(
                      fontSize: titleSmallFont ? 11 : 12,
                      color: colorScheme.onSurface,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (showTags)
          BookDisplayTagsRow(
            tags: tags,
            height: effectiveTagRowHeight,
            compact: true,
          )
        else if (reserveTags)
          SizedBox(height: effectiveTagRowHeight),
      ],
    );
    if (cardColor == 0) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color(cardColor),
        borderRadius: BorderRadius.circular(coverCornerRadius),
      ),
      child: content,
    );
  }
}
