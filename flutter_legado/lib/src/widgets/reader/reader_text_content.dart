import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../widgets/paragraph_layout_engine.dart';
import 'review_column.dart';
import 'text_selection_panel.dart';

/// 段评角标点击（段落索引 1-based、评论数）
typedef ReviewTapCallback = void Function(int paragraphIndex, int count);

/// 阅读器正文排版渲染
///
/// 移植自安卓端 TextChapterLayout 的页面渲染逻辑：
/// - 首屏显示章节标题
/// - 正文使用排版引擎的分行结果渲染
/// - 支持两端对齐、首行缩进、中文避头尾
class ReaderTypographicPage extends StatelessWidget {
  final PageInfo? pageInfo;
  final int pageIndex;
  final int totalPages;
  final String? chapterTitle;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final Color backgroundColor;
  final Color textColor;

  /// 全局页索引（跨章节连续编号，可选）
  final int? globalPageIndex;

  /// 全局总页数（可选）
  final int? globalTotalPages;

  // [UI-fix v2.0.3 | 2026-08-06] 页面内容边距接阅读配置（对标原版
  // ReadBookConfig 四向 padding），默认保持历史硬编码值 — Qoder
  final EdgeInsets contentPadding;

  // [UI-fix v2.0.3 | 2026-08-08] 长按选择文本开关（对标原版 selectText，
  // 关闭后长按正文不再弹出选区面板）— Qoder
  final bool selectText;

  // [UI-fix v2.0.4 | 2026-08-08] 分页页渲染补齐排版参数透传：字距/字体/
  // 两端对齐/字重（此前分页模式仅测量时生效、渲染未应用导致宽度不一致；
  // 字重对标原版 textBold → TextPaint.typeface 加粗/细体）— Qoder
  final double letterSpacing;
  final String? fontFamily;
  final bool justify;
  final FontWeight? fontWeight;

  final Map<int, int>? reviewCounts;
  final ReviewTapCallback? onReviewTap;

  const ReaderTypographicPage({
    super.key,
    required this.pageInfo,
    required this.pageIndex,
    required this.totalPages,
    required this.chapterTitle,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.backgroundColor,
    required this.textColor,
    this.globalPageIndex,
    this.globalTotalPages,
    this.contentPadding =
        const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    this.selectText = true,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.justify = true,
    this.fontWeight,
    this.reviewCounts,
    this.onReviewTap,
  });

  @override
  Widget build(BuildContext context) {
    // 分页结果尚未就绪时显示加载状态
    final info = pageInfo;
    if (info == null) {
      return Center(
        child: Text(
          AppStrings.noContent,
          style: TextStyle(
              fontSize: fontSize, color: textColor.withValues(alpha: 0.5)),
        ),
      );
    }

    return Container(
      color: backgroundColor,
      padding: contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一页显示章节标题
          if (pageIndex == 0 && chapterTitle != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                chapterTitle!,
                style: TextStyle(
                  fontSize: fontSize + 4,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ),
          // 使用排版引擎渲染分页内容
          Expanded(
            child: ReaderTextContent(
              pageInfo: info,
              fontSize: fontSize,
              lineHeight: lineHeight,
              paragraphSpacing: paragraphSpacing,
              textColor: textColor,
              // [UI-fix v2.0.3 | 2026-08-08] selectText 开关透传 — Qoder
              selectText: selectText,
              // [UI-fix v2.0.4 | 2026-08-08] 字距/字体/对齐/字重透传 — Qoder
              letterSpacing: letterSpacing,
              fontFamily: fontFamily,
              justify: justify,
              fontWeight: fontWeight,
              reviewCounts: reviewCounts,
              onReviewTap: onReviewTap,
            ),
          ),
          // 页码指示（对齐安卓端底部页码显示）
          // 显示格式："章内页/章总页 · 全局页/全局总页"
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: Text(
                _buildPageIndicator(),
                style: TextStyle(
                  fontSize: 11,
                  color: textColor.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建页码指示文本
  ///
  /// 格式："章内页/章总页" 或 "章内页/章总页 · 全局页/全局总页"
  String _buildPageIndicator() {
    final localIndicator = '${pageIndex + 1}/$totalPages';
    final gIndex = globalPageIndex;
    final gTotal = globalTotalPages;
    if (gIndex != null && gTotal != null && gTotal > 0) {
      return '$localIndicator · ${gIndex + 1}/$gTotal';
    }
    return localIndicator;
  }
}

/// 单页排版内容（逐行渲染，支持两端对齐）
///
/// 移植自 TextChapterLayout.kt 的 addCharsToLineFirst/Middle/Natural
class ReaderTextContent extends StatelessWidget {
  final PageInfo pageInfo;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final Color textColor;

  // [UI-fix v2.0.2 | 2026-08-06] 字距调节与字体选择接入渲染
  // （对标原版 ReadBookConfig.letterSpacing/textFont） — Qoder
  final double letterSpacing;
  final String? fontFamily;

  /// 两端对齐开关（对标 MoreConfig textFullJustify）
  final bool justify;

  // [UI-fix v2.0.3 | 2026-08-08] 长按选择文本开关（对标原版 selectText，
  // 关闭后长按不弹选区面板，对标 ReadView.textSelectAble 事件语义）— Qoder
  final bool selectText;

  // [UI-fix v2.0.4 | 2026-08-08] 文字字重（对标原版 textBold：中/粗/细，
  // null=正常字重）— Qoder
  final FontWeight? fontWeight;

  /// 段评摘要：段落索引 → 评论数（P2-9 ruleReview）
  final Map<int, int>? reviewCounts;

  /// 段评角标点击
  final ReviewTapCallback? onReviewTap;

  const ReaderTextContent({
    super.key,
    required this.pageInfo,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.textColor,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.justify = true,
    this.selectText = true,
    this.fontWeight,
    this.reviewCounts,
    this.onReviewTap,
  });

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];
    final availableWidth = MediaQuery.of(context).size.width - 40;

    for (var paraIdx = 0; paraIdx < pageInfo.paragraphs.length; paraIdx++) {
      final para = pageInfo.paragraphs[paraIdx];

      // 段落间距（非第一段时添加）
      if (paraIdx > 0 && lineHeight > 0) {
        widgets.add(SizedBox(height: paragraphSpacing));
      }

      // 逐行渲染
      final lineWidgets = <Widget>[];
      for (var lineIdx = 0; lineIdx < para.lines.length; lineIdx++) {
        final line = para.lines[lineIdx];
        final text = line.words.join('');
        final isLastLine = lineIdx == para.lines.length - 1;
        final isSingleLine = para.lines.length == 1;

        // 两端对齐：非最后一行且非单行时分配额外字间距
        double extraLetterSpacing = 0.0;
        // [UI-fix v2.0.2 | 2026-08-06] 关闭两端对齐时不再拉伸字距
        // （对标 MoreConfig textFullJustify 开关） — Qoder
        final shouldJustify = justify && !isLastLine && !isSingleLine;
        if (shouldJustify && line.width > 0) {
          if (line.width < availableWidth) {
            final gapCount = line.words.length - 1;
            if (gapCount > 0) {
              extraLetterSpacing = (availableWidth - line.width) / gapCount;
              // 限制最大字间距避免过度拉伸
              extraLetterSpacing =
                  extraLetterSpacing.clamp(0.0, fontSize * 0.5);
            }
          }
        }

        lineWidgets.add(
          SizedBox(
            height: fontSize * lineHeight,
            // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂行：放宽宽度约束至
            // availableWidth + hangingWidth 避免裁剪，行起点左移 hangingWidth
            // 使起始引号悬挂进缩进区（对齐原版 TextLine.hangingPunctuation
            // 语义）— Reasonix
            child: line.hangingWidth > 0
                ? OverflowBox(
                    alignment: Alignment.centerLeft,
                    maxWidth: availableWidth + line.hangingWidth,
                    child: Transform.translate(
                      offset: Offset(-line.hangingWidth, 0),
                      child: Text(
                        text,
                        style: TextStyle(
                          fontSize: fontSize,
                          height: lineHeight,
                          color: textColor,
                          fontFamily: fontFamily,
                          fontWeight: fontWeight,
                          letterSpacing:
                              (letterSpacing + extraLetterSpacing) != 0
                                  ? letterSpacing + extraLetterSpacing
                                  : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  )
                : Text(
                    text,
                    style: TextStyle(
                      fontSize: fontSize,
                      height: lineHeight,
                      color: textColor,
                      fontFamily: fontFamily,
                      fontWeight: fontWeight,
                      letterSpacing: (letterSpacing + extraLetterSpacing) != 0
                          ? letterSpacing + extraLetterSpacing
                          : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  ),
          ),
        );
      }

      // [UI-fix v2.0.1 | 2026-08-06] 段落级长按入口：弹出选区操作面板
      // （对齐原版 ReadView.onLongPress → showTextActionMenu；P0-1 审计修复）
      // [UI-fix v2.0.3 | 2026-08-08] selectText 关闭时移除长按入口 — Qoder
      final paraText = para.lines.map((l) => l.words.join('')).join();
      final reviewCount = (para.isParagraphEnd &&
              para.chapterParagraphIndex > 0 &&
              reviewCounts != null)
          ? (reviewCounts![para.chapterParagraphIndex] ?? 0)
          : 0;
      final paragraphBody = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lineWidgets,
      );
      widgets.add(
        GestureDetector(
          onLongPress: (paraText.trim().isEmpty || !selectText)
              ? null
              : () => TextSelectionPanel.show(
                    context,
                    text: paraText,
                    chapterPos: para.startIndex,
                  ),
          child: reviewCount > 0
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: paragraphBody),
                    ReviewColumnBadge(
                      count: reviewCount,
                      onTap: onReviewTap == null
                          ? null
                          : () => onReviewTap!(
                                para.chapterParagraphIndex,
                                reviewCount,
                              ),
                    ),
                  ],
                )
              : paragraphBody,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

/// 滚动模式下的段落渲染（未分页时使用，应用配置的段落间距）
class ReaderParagraphs extends StatelessWidget {
  final String content;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final Color textColor;

  // [UI-fix v2.0.2 | 2026-08-06] 滚动回退渲染同步字距/字体 — Qoder
  final double letterSpacing;
  final String? fontFamily;

  // [UI-fix v2.0.3 | 2026-08-08] 长按选择文本开关 — Qoder
  final bool selectText;

  // [UI-fix v2.0.4 | 2026-08-08] 文字字重（对标原版 textBold）— Qoder
  final FontWeight? fontWeight;

  const ReaderParagraphs({
    super.key,
    required this.content,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.textColor,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.selectText = true,
    this.fontWeight,
  });

  @override
  Widget build(BuildContext context) {
    final paragraphs = content.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in paragraphs)
          // [UI-fix v2.0.1 | 2026-08-06] 滚动回退模式段落级长按入口
          // [UI-fix v2.0.3 | 2026-08-08] selectText 关闭时移除长按入口 — Qoder
          GestureDetector(
            onLongPress: (p.trim().isEmpty || !selectText)
                ? null
                : () => TextSelectionPanel.show(context, text: p),
            child: Padding(
              padding: EdgeInsets.only(bottom: paragraphSpacing),
              child: Text(
                p.isEmpty ? ' ' : p,
                style: TextStyle(
                  fontSize: fontSize,
                  height: lineHeight,
                  color: textColor,
                  fontFamily: fontFamily,
                  // [UI-fix v2.0.4 | 2026-08-08] 字重接线 — Qoder
                  fontWeight: fontWeight,
                  letterSpacing: letterSpacing != 0 ? letterSpacing : null,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
