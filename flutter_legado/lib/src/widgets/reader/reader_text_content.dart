import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../models/highlight_style.dart';
import '../../utils/reader_inline_image.dart';
import '../../widgets/paragraph_layout_engine.dart';
import 'highlight_span_builder.dart';
import 'reader_bookmark_badge.dart';
import 'reader_inline_image_widget.dart';
import 'review_column.dart';
import 'reader_page_chrome.dart';
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

  /// [P2-2] 分页快照章节索引（加载冻结帧优先于阅读状态）
  final int? chapterIndex;

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

  // [C3 斜体 | Qoder UI] 正文斜体（与 fontWeight 同链路透传，测量/渲染同参）
  final FontStyle? fontStyle;

  // [UI-fix v2.0.59 | 2026-08-14] 页眉/页脚提示与标题样式 — Cursor UI
  final ReaderPageChromeConfig pageChrome;
  final ReaderTipContext tipContext;

  final Map<int, int>? reviewCounts;
  final ReviewTapCallback? onReviewTap;

  /// [批34] 本章高亮命中区间（UTF-16 章节全局偏移，互不重叠）
  final List<HighlightMatch> highlightMatches;

  /// [批4d] 本页是否有书签（角标不参与滚动模式，由调用方只在分页页传入）
  final bool showBookmarkBadge;

  /// [批4d] 角标自定义图相对标识（空/缺失回落默认琥珀）
  final String bookmarkBadgeImage;

  /// [批4d] 角标大小 dp（<=0 隐藏）
  final int bookmarkBadgeSize;

  // [批16] 正文图片渲染配置（字节加载/点击档位/预览回调）与章节标题图
  // 布局（首屏标题下方，高度已计入首页分页容量）。
  final ReaderImageRenderConfig imageConfig;
  final ReaderImageLayout? titleImageLayout;

  const ReaderTypographicPage({
    super.key,
    required this.pageInfo,
    required this.pageIndex,
    required this.totalPages,
    required this.chapterTitle,
    this.chapterIndex,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.backgroundColor,
    required this.textColor,
    this.globalPageIndex,
    this.globalTotalPages,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 24,
    ),
    this.pageChrome = const ReaderPageChromeConfig(),
    this.tipContext = const ReaderTipContext(pageIndex: 0, totalPages: 1),
    this.selectText = true,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.justify = true,
    this.fontWeight,
    this.fontStyle,
    this.reviewCounts,
    this.onReviewTap,
    this.highlightMatches = const [],
    this.showBookmarkBadge = false,
    this.bookmarkBadgeImage = '',
    this.bookmarkBadgeSize = 10,
    this.imageConfig = const ReaderImageRenderConfig(),
    this.titleImageLayout,
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
            fontSize: fontSize,
            color: textColor.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    final chrome = pageChrome;
    final showHeader = chrome.showPageHeader && chrome.hasHeaderTips;
    final showFooter = chrome.showPageFooter && chrome.hasFooterTips;
    final showTitle =
        pageIndex == 0 &&
        chapterTitle != null &&
        chrome.titleMode.clamp(0, 2) != 2;
    final titleAlign = switch (chrome.titleMode.clamp(0, 2)) {
      1 => TextAlign.center,
      _ => TextAlign.start,
    };

    final pageContent = Container(
      color: backgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader)
            ReaderPageTipBar(
              padding: EdgeInsets.fromLTRB(
                chrome.headerPaddingLeft,
                chrome.headerPaddingTop,
                chrome.headerPaddingRight,
                chrome.headerPaddingBottom,
              ),
              leftTip: chrome.tipHeaderLeft,
              middleTip: chrome.tipHeaderMiddle,
              rightTip: chrome.tipHeaderRight,
              tipContext: tipContext,
              textColor: textColor,
              showDivider: chrome.showHeaderLine,
              dividerOnTop: false,
            ),
          Expanded(
            child: Padding(
              padding: contentPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showTitle)
                    Padding(
                      padding: EdgeInsets.only(
                        top: chrome.titleTopSpacing.toDouble(),
                        bottom: chrome.titleBottomSpacing.toDouble(),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: titleAlign == TextAlign.center
                                ? Alignment.center
                                : Alignment.centerLeft,
                            child: Text(
                              chapterTitle!,
                              textAlign: titleAlign,
                              style: TextStyle(
                                fontSize: fontSize + chrome.titleSize,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                                // [C3 标题字体] 与测量侧同参（effectiveTitleFontFamily
                                // 单源）；同时修复既有偏差：空=跟随正文字体，标题
                                // 随自定义正文自定义字体生效 — full-stack-engineer
                                fontFamily: effectiveTitleFontFamily(
                                  chrome,
                                  fontFamily,
                                ),
                              ),
                            ),
                          ),
                          // [批16] 章节标题图（`BookChapter.imgUrl`）：对齐上游
                          // TextChapterLayout.kt:326-380，首屏标题下方展示；
                          // 高度已由阅读页计入首页分页容量（同一布局单源）。
                          if (titleImageLayout != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: ReaderImageLineWidget(
                                layout: titleImageLayout!,
                                config: imageConfig,
                              ),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ClipRect(
                      // 防分页测量与渲染亚像素差导致的行溢出条纹
                      child: ReaderTextContent(
                        pageInfo: info,
                        fontSize: fontSize,
                        lineHeight: lineHeight,
                        paragraphSpacing: paragraphSpacing,
                        textColor: textColor,
                        selectText: selectText,
                        letterSpacing: letterSpacing,
                        fontFamily: fontFamily,
                        justify: justify,
                        fontWeight: fontWeight,
                        fontStyle: fontStyle,
                        reviewCounts: reviewCounts,
                        onReviewTap: onReviewTap,
                        highlightMatches: highlightMatches,
                        chapterIndex: chapterIndex,
                        chapterTitle: chapterTitle,
                        imageConfig: imageConfig,
                      ),
                    ),
                  ),
                  if (!showFooter)
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
            ),
          ),
          if (showFooter)
            ReaderPageTipBar(
              padding: EdgeInsets.fromLTRB(
                chrome.footerPaddingLeft,
                chrome.footerPaddingTop,
                chrome.footerPaddingRight,
                chrome.footerPaddingBottom,
              ),
              leftTip: chrome.tipFooterLeft,
              middleTip: chrome.tipFooterMiddle,
              rightTip: chrome.tipFooterRight,
              tipContext: tipContext,
              textColor: textColor,
              showDivider: chrome.showFooterLine,
              dividerOnTop: true,
            ),
        ],
      ),
    );
    // [批4d] 角标叠在整页内容上：顶部 = 页眉块高 + 正文 contentTop + 内缩
    // （path 自带顶部内缩，topInset 现为 0）；右侧 = 正文 right padding+6dp。
    if (!showBookmarkBadge || bookmarkBadgeSize <= 0) return pageContent;
    final badgeTop =
        ReaderPageLayoutMetrics.headerBlockHeight(context, chrome) +
        contentPadding.top +
        ReaderBookmarkBadgeGeometry.topInset;
    return Stack(
      fit: StackFit.expand,
      children: [
        pageContent,
        Positioned(
          top: badgeTop,
          right: contentPadding.right + ReaderBookmarkBadgeGeometry.rightInset,
          child: ReaderBookmarkBadge(
            size: bookmarkBadgeSize,
            image: bookmarkBadgeImage,
          ),
        ),
      ],
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

  // [C3 斜体 | Qoder UI] 正文斜体（与 fontWeight 同链路透传，测量/渲染同参）
  final FontStyle? fontStyle;

  /// 段评摘要：段落索引 → 评论数（P2-9 ruleReview）
  final Map<int, int>? reviewCounts;

  /// 段评角标点击
  final ReviewTapCallback? onReviewTap;

  /// [批34] 本章高亮命中区间（UTF-16 章节全局偏移）
  final List<HighlightMatch> highlightMatches;

  /// [P2-2] 分页快照章节索引/标题（长按选区时优先于实时阅读状态）
  final int? chapterIndex;
  final String? chapterTitle;

  /// [批16] 正文图片渲染配置
  final ReaderImageRenderConfig imageConfig;

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
    this.fontStyle,
    this.reviewCounts,
    this.onReviewTap,
    this.highlightMatches = const [],
    this.chapterIndex,
    this.chapterTitle,
    this.imageConfig = const ReaderImageRenderConfig(),
  });

  @override
  Widget build(BuildContext context) {
    // [UI_SYNC_REFACTOR S4 修 | 2026-09-06] 两端对齐的可用宽改用实际布局
    // 约束——此前硬编码屏宽-40，自定义页面边距（contentPadding ≠ 20×2）
    // 时对齐目标宽与渲染约束错位，拉伸后行宽超约束被裁（行尾吞字）— Qoder
    return LayoutBuilder(
      builder: (context, constraints) {
        final widgets = <Widget>[];
        final availableWidth = constraints.maxWidth;

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
            final isLastLine = lineIdx == para.lines.length - 1;
            final isSingleLine = para.lines.length == 1;

            // [批16] 独立图片行：不参与文字对齐/字距，按图片布局渲染
            if (line.imageLayout != null) {
              lineWidgets.add(
                ReaderImageLineWidget(
                  layout: line.imageLayout!,
                  config: imageConfig,
                ),
              );
              continue;
            }

            final text = line.words.join('');
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
                  extraLetterSpacing = extraLetterSpacing.clamp(
                    0.0,
                    fontSize * 0.5,
                  );
                }
              }
            }

            final lineTextStyle = TextStyle(
              fontSize: fontSize,
              height: lineHeight,
              color: textColor,
              fontFamily: fontFamily,
              fontWeight: fontWeight,
              fontStyle: fontStyle,
              letterSpacing: (letterSpacing + extraLetterSpacing) != 0
                  ? letterSpacing + extraLetterSpacing
                  : null,
            );

            // [批16] 含行内图片的行：占位符替换为 WidgetSpan，文字分段
            // 继承同一行样式/高亮
            final lineText = line.inlineImages.isNotEmpty
                ? _buildInlineImageLine(line, text, lineTextStyle)
                // [批34] 命中行改 Text.rich：按章节全局偏移切分 span，只应用
                // 不影响字体度量的样式（颜色/背景/下划线/删除线）— full-stack-engineer
                : highlightMatches.isEmpty || !line.highlightMapped
                ? Text(
                    text,
                    style: lineTextStyle,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  )
                : Text.rich(
                    TextSpan(
                      children: buildHighlightedLineSpans(
                        text: text,
                        chapterStart: line.chapterStartIndex,
                        highlightSkip: line.highlightSkip,
                        matches: highlightMatches,
                      ),
                    ),
                    style: lineTextStyle,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  );

            lineWidgets.add(
              SizedBox(
                // [批16] 行高取排版结果（纯文本恒为 fontSize*lineHeight；
                // 行内小图行按图片显示高度抬升）
                height: line.height,
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
                          child: lineText,
                        ),
                      )
                    : lineText,
              ),
            );
          }

          // [UI-fix v2.0.1 | 2026-08-06] 段落级长按入口：弹出选区操作面板
          // （对齐原版 ReadView.onLongPress → showTextActionMenu；P0-1 审计修复）
          // [UI-fix v2.0.3 | 2026-08-08] selectText 关闭时移除长按入口 — Qoder
          final paraText = para.lines
              .map(
                (l) =>
                    l.words.join('').replaceAll(readerImagePlaceholderChar, ''),
              )
              .join();
          final reviewCount =
              (para.isParagraphEnd &&
                  para.chapterParagraphIndex > 0 &&
                  reviewCounts != null)
              ? (reviewCounts![para.chapterParagraphIndex] ?? 0)
              : 0;
          final paragraphBody = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lineWidgets,
          );
          // [UI_SYNC_REFACTOR S6 | 2026-09-08] 长按交互改造（用户裁决 A：
          // 对齐参考版浮窗）：长按段落于按压点浮出工具条（复制/分享/浏览器/
          // 朗读/书签/更多）；「更多」打开保留的段落面板（替换/高亮/词典/
          // 搜正文/精细选区增强动作不丢失）。
          // 注：SelectionArea 在阅读器 PageView 手势栈下长按不触发
          // （组件测试正常/真机不触发，探针实证父级赢得竞技场），故采用
          // 长按点 Overlay 浮条方案，形态对齐且行为确定 — Qoder
          Widget paragraphContent = reviewCount > 0
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
              : paragraphBody;
          if (selectText && paraText.trim().isNotEmpty) {
            paragraphContent = GestureDetector(
              onLongPressStart: (details) {
                ReaderSelectionToolbar.show(
                  context,
                  anchor: details.globalPosition,
                  text: paraText,
                  chapterPos: para.startIndex,
                  chapterIndex: chapterIndex,
                  chapterTitle: chapterTitle,
                );
              },
              child: paragraphContent,
            );
          }
          widgets.add(paragraphContent);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: widgets,
        );
      },
    );
  }

  /// 构建含行内图片的文本行（占位符 → WidgetSpan）
  ///
  /// 排版按占位符宽度断行，渲染用同宽 WidgetSpan 替换，保证行宽与分页
  /// 结果一致；文字分段沿用同一行样式，高亮按分段偏移映射。
  Widget _buildInlineImageLine(LineInfo line, String text, TextStyle style) {
    final spans = <InlineSpan>[];
    var segmentStart = 0;
    var imageIndex = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 0xFFFC) continue;
      if (i > segmentStart) {
        spans.addAll(
          _inlineTextSpans(line, text.substring(segmentStart, i), segmentStart),
        );
      }
      if (imageIndex < line.inlineImages.length) {
        final layout = line.inlineImages[imageIndex];
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: ReaderInlineImageWidget(
              image: layout.image,
              width: layout.width,
              height: layout.height,
              config: imageConfig,
            ),
          ),
        );
      }
      imageIndex++;
      segmentStart = i + 1;
    }
    if (segmentStart < text.length) {
      spans.addAll(
        _inlineTextSpans(line, text.substring(segmentStart), segmentStart),
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }

  /// 行内图片行的文字分段 span（高亮偏移按分段起点换算）
  List<InlineSpan> _inlineTextSpans(
    LineInfo line,
    String segment,
    int offsetInLine,
  ) {
    if (highlightMatches.isEmpty || !line.highlightMapped) {
      return [TextSpan(text: segment)];
    }
    // [批16 三审 P2-5] 行内图片占位符对应整段 `<img>` 标签，优先用逐字符
    // 章节偏移映射；无映射时回落既有线性公式。
    final mapped = line.chapterOffsetAt(offsetInLine);
    final chapterStart =
        mapped ?? line.chapterStartIndex + (offsetInLine - line.highlightSkip);
    return buildHighlightedLineSpans(
      text: segment,
      chapterStart: chapterStart < 0 ? 0 : chapterStart,
      highlightSkip: 0,
      matches: highlightMatches,
    );
  }
}

/// 滚动模式下的段落渲染（未分页时使用，应用配置的段落间距）
class ReaderParagraphs extends StatelessWidget {
  final String content;

  /// [P2-2] 分页快照章节索引/标题（滚动模式长按选区使用，避免冻结帧错章）
  final int? chapterIndex;
  final String? chapterTitle;

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

  // [C3 斜体 | Qoder UI] 正文斜体（与 fontWeight 同链路透传，测量/渲染同参）
  final FontStyle? fontStyle;

  const ReaderParagraphs({
    super.key,
    required this.content,
    this.chapterIndex,
    this.chapterTitle,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.textColor,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.selectText = true,
    this.fontWeight,
    this.fontStyle,
  });

  @override
  Widget build(BuildContext context) {
    final paragraphs = content.split('\n');
    // [P2-2 低成本] 滚动模式无分页 ParagraphInfo：按行累计段首偏移，
    // 传给选区面板（此前恒 0，笔记/高亮锚点全落在章首）
    var offset = 0;
    final items = <Widget>[];
    for (var index = 0; index < paragraphs.length; index++) {
      final p = paragraphs[index];
      final leading = p.length - p.trimLeft().length;
      final paragraphChapterPos = offset + leading;
      items.add(
        // [UI-fix v2.0.1 | 2026-08-06] 滚动回退模式段落级长按入口
        // [UI-fix v2.0.3 | 2026-08-08] selectText 关闭时移除长按入口 — Qoder
        GestureDetector(
          onLongPress: (p.trim().isEmpty || !selectText)
              ? null
              : () => TextSelectionPanel.show(
                  context,
                  text: p,
                  chapterPos: paragraphChapterPos,
                  chapterIndex: chapterIndex,
                  chapterTitle: chapterTitle,
                ),
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
                fontStyle: fontStyle,
                letterSpacing: letterSpacing != 0 ? letterSpacing : null,
              ),
            ),
          ),
        ),
      );
      offset += p.length + 1; // + '\n'
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items,
    );
  }
}
