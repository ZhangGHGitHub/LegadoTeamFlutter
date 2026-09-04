import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/models.dart';
import '../utils/book_progress_utils.dart';
import '../utils/time_utils.dart';
import 'book_cover.dart';

/// 书架列表项（对标原版 item_bookshelf_list.xml）
///
/// 结构：
/// - 左侧 66x90 封面（垂直居中）
/// - 右侧 4 行信息：书名 16sp（右上未读角标）/ 作者 + 更新时间 13sp /
///   阅读章节 13sp / 最新章节 13sp + 阅读百分比 11sp
/// - 底部 2dp 阅读进度条（无阅读记录时隐藏）
class BookListItem extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const BookListItem({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final unread = unreadChapterNum(book);
    final progress = bookReadProgress(book);
    final summaryStyle = TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 16, top: 4, bottom: 4),
        child: Row(
          children: [
            BookCover(
              coverUrl: book.customCoverUrl ?? book.coverUrl,
              width: 66,
              height: 90,
              borderRadius: 4,
              sourceOrigin: book.origin,
              // Hero 封面过渡（书架↔详情，key=book url）
              // [LAYOUT_MOTION_AUDIT M1] tag 统一 book-cover:（HapeLee 同义键）
              heroTag: 'book-cover:${book.bookUrl}',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 书名行 + 右上未读角标（对标 tv_name + bv_unread）
                  Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4, left: 2),
                          child: Text(
                            book.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      if (unread > 0) _UnreadBadge(count: unread),
                    ],
                  ),
                  // 作者 + 更新时间行（对标 iv_author + tv_author + tv_last_update_time）
                  _SummaryRow(
                    icon: Symbols.person_rounded,
                    text: book.author,
                    style: summaryStyle,
                    trailing: book.latestChapterTime > 0
                        ? Text(
                            timeAgo(book.latestChapterTime),
                            maxLines: 1,
                            style: summaryStyle,
                          )
                        : null,
                  ),
                  // 阅读进度行（对标 iv_read + tv_read：显示当前阅读章节）
                  if ((book.durChapterTitle ?? '').isNotEmpty)
                    _SummaryRow(
                      icon: Symbols.history_rounded,
                      text: book.durChapterTitle!,
                      style: summaryStyle,
                    ),
                  // 最新章节行 + 百分比（对标 iv_last + tv_last + tv_read_percent）
                  if ((book.latestChapterTitle ?? '').isNotEmpty)
                    _SummaryRow(
                      icon: Symbols.last_page_rounded,
                      text: book.latestChapterTitle!,
                      style: summaryStyle,
                      trailing: progress != null
                          ? Text(
                              '${(progress * 100).round()}%',
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            )
                          : null,
                    ),
                  // 底部阅读进度条（对标 pb_read_progress，2dp，accent 色）
                  if (progress != null) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(1),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 2,
                        backgroundColor: colorScheme.primary
                            .withValues(alpha: 0.2),
                        valueColor:
                            AlwaysStoppedAnimation(colorScheme.primary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 摘要行：小图标 + 文本 +（可选）右侧尾随文本
class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final TextStyle style;
  final Widget? trailing;

  const _SummaryRow({
    required this.icon,
    required this.text,
    required this.style,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, top: 1),
      child: Row(
        children: [
          Icon(icon, size: 13, color: style.color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 未读章节数角标（对标 BadgeView bv_unread）
class _UnreadBadge extends StatelessWidget {
  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(5),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      decoration: BoxDecoration(
        color: colorScheme.error,
        borderRadius: BorderRadius.circular(9),
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
    );
  }
}
