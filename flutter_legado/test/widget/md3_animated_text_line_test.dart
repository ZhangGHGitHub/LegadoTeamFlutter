// MD3 动画文本行测试（对齐参考 AnimatedTextLine：文本变化翻滚切换）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/md3_animated_text_line.dart';

void main() {
  Widget wrap(String text) => MaterialApp(
        home: Scaffold(
          body: Center(child: Md3AnimatedTextLine(text: text)),
        ),
      );

  testWidgets('初始渲染文本', (tester) async {
    await tester.pumpWidget(wrap('1'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('文本变化时翻滚到新文本（数字递增场景）', (tester) async {
    await tester.pumpWidget(wrap('1'));
    await tester.pumpAndSettle();

    // 模拟聚合搜索流式返回：数字 1 → 2 → 3
    await tester.pumpWidget(wrap('2'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    await tester.pumpWidget(wrap('3'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsNothing);
  });
}
