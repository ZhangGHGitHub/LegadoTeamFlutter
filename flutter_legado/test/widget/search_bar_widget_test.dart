import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_legado/src/widgets/search_bar_widget.dart';

void main() {
  Widget buildTestWidget({
    String hintText = '搜索书籍',
    ValueChanged<String>? onChanged,
    VoidCallback? onClear,
    VoidCallback? onSubmit,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SearchBarWidget(
            hintText: hintText,
            onChanged: onChanged ?? (_) {},
            onClear: onClear,
            onSubmit: onSubmit,
          ),
        ),
      ),
    );
  }

  testWidgets('SearchBarWidget renders with hint text', (tester) async {
    await tester.pumpWidget(buildTestWidget(hintText: '搜索书源'));

    expect(find.text('搜索书源'), findsOneWidget);
    expect(find.byIcon(Symbols.search_rounded), findsOneWidget);
  });

  testWidgets('SearchBarWidget shows clear button when text entered',
      (tester) async {
    await tester.pumpWidget(buildTestWidget());

    // 初始状态没有清除按钮
    expect(find.byIcon(Symbols.close_rounded), findsNothing);

    // 输入文字后显示清除按钮
    await tester.enterText(find.byType(TextField), '测试');
    await tester.pump();

    expect(find.byIcon(Symbols.close_rounded), findsOneWidget);
  });

  testWidgets('SearchBarWidget onChanged callback works', (tester) async {
    String? changedText;
    await tester.pumpWidget(buildTestWidget(onChanged: (t) => changedText = t));

    await tester.enterText(find.byType(TextField), '斗破苍穹');
    expect(changedText, '斗破苍穹');
  });

  testWidgets('SearchBarWidget onClear callback works', (tester) async {
    var cleared = false;
    await tester.pumpWidget(buildTestWidget(onClear: () => cleared = true));

    await tester.enterText(find.byType(TextField), '测试');
    await tester.pump();
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pump();

    expect(cleared, isTrue);
  });
}
