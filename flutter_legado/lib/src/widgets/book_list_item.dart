import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/book.dart';
import '../models/bookshelf_settings.dart';
import '../providers/cover_settings/cover_settings_notifier.dart';
import '../utils/book_intro_utils.dart';
import '../utils/book_progress_utils.dart';
import '../utils/time_utils.dart';
import 'book_cover.dart';
import 'book_display_tags_row.dart';
import 'privacy/private_locked_cover.dart';

/// 书架列表项（对齐参考版 `BookItem.kt` BookshelfListItem）
///
/// 结构（设置批6a-1）：
/// - 左侧封面：宽度 40–120（默认 84，高按 5:7 推算），可垂直居中/顶部对齐
/// - 右侧：书名（最大行数 1–5）/ 作者 / 当前章节 / 标签 / 最新章节
///   （「更多信息」总开关控制后三项 + 简介）/ 阅读进度条
/// - 卡片背景色：日间/夜间可配置（0 = 跟随主题）
/// - 底部 0.5dp 分隔线（`bookshelfShowDivider`）
/// - 「精简详情」：只保留书名 + 作者 + 未读数
class BookListItem extends StatelessWidget {
  final Book book;

  /// 书架布局设置（默认值 = 参考版默认，测试/独立使用可直接构造）
  final BookshelfSettings settings;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// [批35] 展示标签（用户标签/书源分类/字数，空列表不渲染）
  final List<String> tags;

  /// 书籍类型标签（`showTip` 开启时的「音频/漫画/本地/文件/小说」）
  final String? typeLabel;

  /// 多列列表时的封面宽度上限（避免窄列里封面吃掉全部文字区）
  final double? maxCoverWidth;

  /// 多列列表时简介行数覆盖（固定 cell 高，避免 0 = 全部时溢出）
  final int? introMaxLinesOverride;

  /// [批9c] 私密且未授权：只渲染模糊封面 + 锁标，不渲染书名/作者/章节/
  /// 标签/简介/进度等任何真实文本
  final bool locked;

  const BookListItem({
    super.key,
    required this.book,
    this.settings = BookshelfSettings.defaults,
    this.tags = const [],
    this.typeLabel,
    this.maxCoverWidth,
    this.introMaxLinesOverride,
    this.locked = false,
    this.onTap,
    this.onLongPress,
  });

  /// 列表封面基础高度（宽 × 7/5；网格多列 cell 高度估算共用）
  static double coverHeightFor(double width) => width * 7 / 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final cardColorValue = settings.cardColorFor(isDark: isDark);
    // [设备回归] 全局阴影在列表卡片外层绘制（内层 BookCover 阴影被 Stack 裁剪）
    final effectiveCoverShadow =
        settings.bookshelfCoverShadow ||
        coverSettingsListenable.value.showShadow;

    final unread = settings.showUnread ? unreadChapterNum(book) : 0;
    final isNew = settings.showUnreadNew && book.lastCheckCount > 0;
    final progress = bookReadProgress(book);
    final compact = settings.bookshelfLayoutCompact;
    final showDetails = settings.showBookIntro && !compact;
    // [审查 P1-1] 多列（窄单元格）模式：缩小内边距、隐藏摘要图标、
    // 收紧角标，避免窄列 + 大字号 + 批量勾选时横向溢出。
    final dense = maxCoverWidth != null;

    final configuredCoverWidth = settings.bookshelfListCoverWidth.toDouble();
    final coverWidth = maxCoverWidth == null
        ? configuredCoverWidth
        : math.min(configuredCoverWidth, maxCoverWidth!);
    final coverHeight = coverHeightFor(coverWidth);

    // [批9c] 锁定行：不渲染任何文本（书名/作者/章节/标签/简介/进度），
    // 只保留模糊封面 + 锁标；高度与普通行一致，滚动不跳动。
    if (locked) {
      return Material(
        color: cardColorValue == 0 ? Colors.transparent : Color(cardColorValue),
        borderRadius: cardColorValue == 0 ? null : BorderRadius.circular(8),
        clipBehavior: cardColorValue == 0 ? Clip.none : Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              label: '已隐藏',
              child: ExcludeSemantics(
                child: InkWell(
                  onTap: onTap,
                  onLongPress: onLongPress,
                  child: Padding(
                    padding: dense
                        ? const EdgeInsets.fromLTRB(4, 8, 4, 8)
                        : const EdgeInsets.only(
                            left: 8,
                            right: 16,
                            top: 12,
                            bottom: 12,
                          ),
                    child: Row(
                      crossAxisAlignment: settings.bookshelfListCoverCenter
                          ? CrossAxisAlignment.center
                          : CrossAxisAlignment.start,
                      children: [
                        PrivateLockedCover(
                          width: coverWidth,
                          height: coverHeight,
                          coverUrl: book.customCoverUrl ?? book.coverUrl,
                          sourceOrigin: book.origin,
                          heroTag: 'book-cover:${book.bookUrl}',
                          borderRadius: 4,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: SizedBox(height: coverHeight)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (settings.bookshelfShowDivider)
              Divider(
                height: 0.5,
                thickness: 0.5,
                indent: 16,
                endIndent: 16,
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
          ],
        ),
      );
    }

    final intro = settings.showBookIntro && settings.bookshelfShowIntro
        ? plainBookIntro(_displayIntro(book))
        : '';
    final showIntro = showDetails && intro.isNotEmpty;
    final introBelow = showIntro && settings.bookshelfListIntroBelowContent;
    final introMaxLines =
        introMaxLinesOverride ??
        (settings.bookshelfIntroMaxLines == 0
            ? null
            : settings.bookshelfIntroMaxLines);

    final subtitleStyle = TextStyle(
      fontSize: 13,
      color: colorScheme.onSurfaceVariant,
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 书名 + 未读角标
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 2),
                child: Text(
                  book.name,
                  maxLines: settings.bookshelfTitleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurface,
                    height: 1.25,
                  ),
                ),
              ),
            ),
            if (unread > 0)
              _UnreadBadge(count: unread, showUpdate: isNew, dense: dense),
          ],
        ),
        // 作者（精简模式附加未读数，对齐参考版 author_read）
        _SummaryRow(
          icon: Symbols.person_rounded,
          text: compact && unread > 0
              ? '${book.author.isEmpty ? '未知作者' : book.author} · $unread 章未读'
              : book.author,
          style: subtitleStyle,
          dense: dense,
        ),
        if (!compact && (book.durChapterTitle ?? '').isNotEmpty)
          _SummaryRow(
            icon: Symbols.history_rounded,
            text: book.durChapterTitle!,
            style: subtitleStyle,
            dense: dense,
          ),
        // 标签（我方扩展批35；精简/未开启更多信息时隐藏）
        if (!compact && showDetails && tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: BookDisplayTagsRow(tags: tags),
          ),
        // 更多信息：简介（内容下方开关关闭时显示在此）
        if (showIntro && !introBelow)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              intro,
              maxLines: introMaxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        // 更多信息：最新章节 +（可选）上次更新时间
        if (showDetails &&
            settings.bookshelfShowLatestChapter &&
            (book.latestChapterTitle ?? '').isNotEmpty)
          _SummaryRow(
            icon: Symbols.last_page_rounded,
            text: book.latestChapterTitle!,
            style: subtitleStyle,
            dense: dense,
            trailing:
                settings.showLastUpdateTime &&
                    !BookType.isLocalBook(book) &&
                    book.latestChapterTime > 0
                ? Text(
                    timeAgo(book.latestChapterTime),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                : progress != null
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
        // 阅读进度条
        if (progress != null) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation(colorScheme.primary),
            ),
          ),
        ],
      ],
    );

    return Material(
      color: cardColorValue == 0 ? Colors.transparent : Color(cardColorValue),
      // 非 0 卡色时给列表卡 8dp 圆角并裁剪，避免直角色块；0 保持透明
      borderRadius: cardColorValue == 0 ? null : BorderRadius.circular(8),
      clipBehavior: cardColorValue == 0 ? Clip.none : Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: dense
                  ? const EdgeInsets.fromLTRB(4, 8, 4, 8)
                  : const EdgeInsets.only(
                      left: 8,
                      right: 16,
                      top: 12,
                      bottom: 12,
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: settings.bookshelfListCoverCenter
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: effectiveCoverShadow
                              ? [
                                  BoxShadow(
                                    color: colorScheme.shadow.withValues(
                                      alpha: 0.18,
                                    ),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: Stack(
                          children: [
                            BookCover(
                              coverUrl: book.customCoverUrl ?? book.coverUrl,
                              bookName: book.name,
                              bookAuthor: book.author,
                              width: coverWidth,
                              height: coverHeight,
                              borderRadius: 4,
                              sourceOrigin: book.origin,
                              // 单列走全局「限制封面比例」（批39 既有能力）；
                              // 多列固定 cell 高度，避免自适应高度撑破网格。
                              adaptAspectRatio: maxCoverWidth == null,
                              adaptiveMinHeight: math.min(66, coverHeight),
                              adaptiveMaxHeight: coverHeight,
                              heroTag: 'book-cover:${book.bookUrl}',
                            ),
                            // 书籍类型标签（左下，对齐参考 leftBottomText）
                            if (typeLabel != null && typeLabel!.isNotEmpty)
                              Positioned(
                                left: 4,
                                bottom: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
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
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: content),
                    ],
                  ),
                  // 更多信息：简介显示在内容下方
                  if (introBelow)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, top: 8),
                      child: Text(
                        intro,
                        maxLines: introMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (settings.bookshelfShowDivider)
            Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 16,
              endIndent: 16,
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
  }

  /// 显示简介（对齐 Kotlin `Book.getDisplayIntro()`）
  static String _displayIntro(Book book) {
    final custom = book.customIntro;
    if (custom == null || custom.isEmpty) return book.intro ?? '';
    return custom;
  }
}

/// 摘要行：小图标 + 文本 +（可选）右侧尾随文本
class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final TextStyle style;
  final Widget? trailing;

  /// 窄列模式：隐藏前导图标，为文字/角标让出横向空间
  final bool dense;

  const _SummaryRow({
    required this.icon,
    required this.text,
    required this.style,
    this.trailing,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: dense ? 0 : 2, top: 1),
      child: Row(
        children: [
          if (!dense) ...[
            Icon(icon, size: 13, color: style.color),
            const SizedBox(width: 4),
          ],
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
            // 窄列/大字号下尾随文本（进度百分比/相对时间）不得撑破 Row：
            // 允许收缩并按 ellipsis 截断，主文本仍优先占用剩余宽度。
            Flexible(fit: FlexFit.loose, child: trailing!),
          ],
        ],
      ),
    );
  }
}

/// 未读章节数角标（对标 BadgeView bv_unread；新章节附刷新图标）
class _UnreadBadge extends StatelessWidget {
  final int count;
  final bool showUpdate;
  final bool dense;

  const _UnreadBadge({
    required this.count,
    this.showUpdate = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: EdgeInsets.all(dense ? 2 : 5),
      padding: EdgeInsets.symmetric(horizontal: dense ? 3 : 5, vertical: 1),
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      decoration: BoxDecoration(
        color: colorScheme.error,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showUpdate) ...[
            Icon(Icons.update, size: 11, color: colorScheme.onError),
            const SizedBox(width: 2),
          ],
          Text(
            count > 99 ? '99+' : '$count',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colorScheme.onError,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
