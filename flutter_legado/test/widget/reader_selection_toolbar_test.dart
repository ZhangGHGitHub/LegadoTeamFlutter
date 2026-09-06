import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';
import 'package:flutter_legado/src/widgets/reader/text_selection_panel.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';

/// 正文长按浮窗（用户裁决 A：对齐参考版浮窗）行为验证：
/// SelectionArea 包裹段落 → 长按出词选 → 自定义浮窗工具条出现
void main() {
  testWidgets('长按正文出现浮窗工具条（复制/分享/浏览器/朗读/书签/更多）',
      (tester) async {
    final pageInfo = PageInfo(
      paragraphs: [
        ParagraphInfo(
          lines: [
            LineInfo(
              words: ['长按测试段落第一行'],
              width: 120,
              height: 24,
              startIndex: 0,
              endIndex: 9,
            ),
          ],
          totalHeight: 24,
          startIndex: 0,
          endIndex: 9,
          chapterParagraphIndex: 1,
          isParagraphEnd: true,
        ),
      ],
      totalHeight: 24,
    );

    // 复现真实手势环境：阅读器 onTapUp 点触区 + PageView 包裹
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onTapUp: (_) {},
            child: PageView(
              children: [
                SingleChildScrollView(
                  child: ReaderTextContent(
                    pageInfo: pageInfo,
                    fontSize: 16,
                    lineHeight: 1.5,
                    paragraphSpacing: 8,
                    textColor: Colors.white,
                    selectText: true,
                  ),
                ),
                const Scaffold(body: Center(child: Text('第2页'))),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 长按正文文本
    await tester.longPress(find.text('长按测试段落第一行'));
    await tester.pumpAndSettle();

    // 浮窗工具条出现（AdaptiveTextSelectionToolbar 的按钮项）
    expect(find.byType(ReaderSelectionToolbar), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
  });
}
