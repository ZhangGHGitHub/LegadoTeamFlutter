import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';

/// [UI-fix v2.0.4 | 2026-08-08] 分页高度回归测试 — Qoder
///
/// 复现并防回归「阅读正文页底部 RenderFlex 溢出」：分页测量的可用高度
/// 必须与渲染容器（ReaderTypographicPage：首页标题块 + Expanded 正文 +
/// 页码指示页脚）严格一致。按 reader_page_view._paginateIfNeeded 的同一
/// 套算法计算首页/后续页容量，满页正文渲染不得出现溢出异常。
void main() {
  const fontSize = 22.0;
  const lineHeight = 1.8;
  const paragraphSpacing = 12.0;
  const marginTop = 24.0;
  const marginBottom = 24.0;
  const marginLeft = 20.0;
  const marginRight = 20.0;
  const chapterTitle = '第一章 满页正文分页高度回归';

  /// 与 reader_page_view._paginateIfNeeded 同参：实测页脚高度
  double measureFooterHeight(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      text: TextSpan(
        text: '0/0',
        style: baseStyle.merge(const TextStyle(fontSize: 11)),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final h = 8 + painter.height;
    painter.dispose();
    return h;
  }

  /// 与 reader_page_view._paginateIfNeeded 同参：实测首页标题块高度
  double measureTitleBlockHeight(BuildContext context, double maxWidth) {
    final baseStyle = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      text: TextSpan(
        text: chapterTitle,
        style: baseStyle.merge(const TextStyle(
          fontSize: fontSize + 4,
          fontWeight: FontWeight.bold,
        )),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final h = painter.height + 20;
    painter.dispose();
    return h;
  }

  /// 生成足以铺满多页的正文
  String buildLongContent() => List.generate(
        60,
        (i) => '这是第${i + 1}段正文内容，用于验证满页分页时不会超出渲染容器高度，'
            '模拟真实小说正文的段落密度与长度，避免测量与渲染两侧高度不一致。',
      ).join('\n');

  /// 按生产链路分页并渲染指定页，返回分页结果
  Future<List<PageInfo>> pumpPage(WidgetTester tester, int pageIndex) async {
    late List<PageInfo> pages;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final size = MediaQuery.of(context).size;
              final availableWidth = size.width - marginLeft - marginRight;
              final footerHeight = measureFooterHeight(context);
              final availableHeight =
                  size.height - footerHeight - marginTop - marginBottom;
              final firstPageHeight = availableHeight -
                  measureTitleBlockHeight(context, availableWidth);

              final engine = ParagraphLayoutEngine(
                config: const ParagraphConfig(
                  fontSize: fontSize,
                  lineHeight: lineHeight,
                  paragraphSpacing: paragraphSpacing,
                ),
                context: context,
              );
              pages = engine.paginateChapter(
                buildLongContent(),
                availableWidth,
                availableHeight,
                firstPageHeight: firstPageHeight,
              );
              final safeIndex = pageIndex.clamp(0, pages.length - 1);
              return ReaderTypographicPage(
                pageInfo: pages[safeIndex],
                pageIndex: safeIndex,
                totalPages: pages.length,
                chapterTitle: chapterTitle,
                fontSize: fontSize,
                lineHeight: lineHeight,
                paragraphSpacing: paragraphSpacing,
                backgroundColor: Colors.white,
                textColor: Colors.black,
                contentPadding: const EdgeInsets.only(
                  left: marginLeft,
                  right: marginRight,
                  top: marginTop,
                  bottom: marginBottom,
                ),
              );
            },
          ),
        ),
      ),
    );
    return pages;
  }

  testWidgets('首页（含章节标题块）满页正文渲染无 RenderFlex 溢出',
      (tester) async {
    final pages = await pumpPage(tester, 0);
    // 分页应产生多页（正文足够长），且首页渲染不抛溢出异常
    expect(pages.length, greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('非首页满页正文渲染无 RenderFlex 溢出', (tester) async {
    await pumpPage(tester, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('每页排版高度不超过对应页容量（首页扣标题块）', (tester) async {
    late List<PageInfo> pages;
    late double availableHeight;
    late double firstPageHeight;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final size = MediaQuery.of(context).size;
            final availableWidth = size.width - marginLeft - marginRight;
            availableHeight = size.height -
                measureFooterHeight(context) -
                marginTop -
                marginBottom;
            firstPageHeight = availableHeight -
                measureTitleBlockHeight(context, availableWidth);
            final engine = ParagraphLayoutEngine(
              config: const ParagraphConfig(
                fontSize: fontSize,
                lineHeight: lineHeight,
                paragraphSpacing: paragraphSpacing,
              ),
              context: context,
            );
            pages = engine.paginateChapter(
              buildLongContent(),
              availableWidth,
              availableHeight,
              firstPageHeight: firstPageHeight,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(pages, isNotEmpty);
    for (var i = 0; i < pages.length; i++) {
      final capacity = i == 0 ? firstPageHeight : availableHeight;
      expect(
        pages[i].totalHeight,
        lessThanOrEqualTo(capacity),
        reason: '第 ${i + 1} 页排版高度 ${pages[i].totalHeight} '
            '超过页容量 $capacity（首页应扣除标题块高度）',
      );
    }
  });
}
