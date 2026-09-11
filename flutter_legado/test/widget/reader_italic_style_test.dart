import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';

/// 斜体贯通测试（差异清单 C3 双基准补齐项）
///
/// 校验两点：① ParagraphConfig 携带并复制 fontStyle（测量侧同参）；
/// ② 正文渲染控件把 fontStyle 落到 TextStyle（渲染侧同参）。
void main() {
  test('ParagraphConfig 携带并 copyWith 保留 fontStyle（测量侧同参）', () {
    const cfg = ParagraphConfig(fontStyle: FontStyle.italic);
    expect(cfg.fontStyle, FontStyle.italic);
    expect(cfg.copyWith().fontStyle, FontStyle.italic);
    expect(cfg.copyWith(fontStyle: FontStyle.normal).fontStyle,
        FontStyle.normal);
  });

  testWidgets('正文段落渲染把 fontStyle 落到 TextStyle（渲染侧同参）',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ReaderParagraphs(
          content: '第一段正文。\n第二段正文。',
          fontSize: 18,
          lineHeight: 1.6,
          paragraphSpacing: 8,
          textColor: Colors.black,
          letterSpacing: 0,
          fontStyle: FontStyle.italic,
        ),
      ),
    ));
    await tester.pump();

    final texts = tester.widgetList<Text>(find.byType(Text)).toList();
    expect(texts, isNotEmpty, reason: '应渲染出正文 Text');
    final styles = texts.map((t) => t.style?.fontStyle).toList();
    expect(
      styles.every((s) => s == FontStyle.italic),
      isTrue,
      reason: '正文 Text 均应携带 fontStyle: italic，实际=$styles',
    );
  });
}
