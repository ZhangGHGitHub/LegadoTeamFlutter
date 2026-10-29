import 'package:flutter/material.dart';

import 'book_cover.dart';
import 'book_display_tags_row.dart';

/// 书架网格项（对标原版 item_bookshelf_grid.xml）
///
/// 结构：
/// - 封面铺满单元格，右上角未读角标（BadgeView bv_unread），
///   封面底部 2dp 阅读进度条（pb_read_progress）
/// - 封面下方书名：12sp、居中、最多 2 行（tv_name）
///
/// 区域分离长按（Flutter 扩展，对齐原版长按打开书籍信息）：
/// - 封面区域长按 → [onCoverLongPress]（打开书籍信息）
/// - 标题区域长按 → [onInfoLongPress]（打开操作菜单）
/// - 点击 → [onTap]（打开阅读/书籍信息）
class BookGridItem extends StatelessWidget {
  /// [批35] 标签行高度下限（父级网格计算 cell 高宽比时须同步使用）
  ///
  /// [批35b P3-4] 实际行高按 textScaler 抬升（见
  /// [BookDisplayTagsRow.heightFor]），父级必须调用同一函数换算，不能
  /// 直接使用本常量。
  static const double tagRowHeight = 20;

  final String title;
  final String? coverUrl;

  /// 书源 origin（封面 coverDecodeJs）
  final String? sourceOrigin;

  /// Hero 过渡标签（书架↔详情封面过渡，约定 `book-cover:<book url>`，
  /// HapeLee BookCoverSharedElement 同义键，M1）
  final String? heroTag;

  /// 未读章节数（>0 时显示右上角角标）
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

  /// [批35] 父级网格是否已按标签行预留高度：为真时即使本书无标签也保留
  /// 等高空行，保证同屏卡片封面高度一致（不因个别书无标签而拉伸）
  final bool reserveTagRow;

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
    this.onTap,
    this.onCoverLongPress,
    this.onInfoLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // [批35b P3-4] 大字号/无障碍缩放时按 textScaler 抬升预留行高，
    // 与父级 cell 高宽比换算共用 heightFor（否则标签文字被裁切）
    final effectiveTagRowHeight = BookDisplayTagsRow.heightFor(
      context,
      compact: true,
      minHeight: tagRowHeight,
    );

    return Column(
      children: [
        // 封面区域：右上角标 + 底部进度条；长按打开书籍信息
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            onLongPress: onCoverLongPress,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // [骨架对齐 2.0.260 | 台账 1-3] 封面卡片圆角 12（对齐参考 03b）
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    // [审计修复 §3.3] 阴影改用 colorScheme.shadow Token — Qoder
                    color: colorScheme.shadow.withValues(alpha: 0.10),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                // [骨架对齐 2.0.260 | 台账 1-3] 与外层卡片圆角 12 保持一致（对齐参考 03b）
                borderRadius: BorderRadius.circular(12),
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
                      // 未读角标（对标 bv_unread，右上角）
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
                                topRight: Radius.circular(10),
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
                      // 封面底部阅读进度条（对标 pb_read_progress，2dp）
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
                            valueColor:
                                AlwaysStoppedAnimation(colorScheme.primary),
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
        // 书名区域：12sp 居中最多 2 行（对标 tv_name）；长按打开操作菜单
        GestureDetector(
          onTap: onTap,
          onLongPress: onInfoLongPress,
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.topCenter,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
        // [批35] 展示标签（用户标签/书源分类/字数）：空列表不占位；
        // 父级已预留行高时空出一行，保证同屏卡片封面等高
        if (tags.isNotEmpty)
          BookDisplayTagsRow(
            tags: tags,
            height: effectiveTagRowHeight,
            compact: true,
          )
        else if (reserveTagRow)
          SizedBox(height: effectiveTagRowHeight),
      ],
    );
  }
}
