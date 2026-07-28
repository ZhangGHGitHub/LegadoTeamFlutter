import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/bottom_sheet_widget.dart';

void main() {
  Widget buildTestWidget({
    String title = '设置',
    List<Widget> children = const [],
    Widget? trailing,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                AppBottomSheet.show(
                  context: context,
                  title: title,
                  children: children,
                  trailing: trailing,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('AppBottomSheet renders title and children', (tester) async {
    await tester.pumpWidget(buildTestWidget(
      title: '阅读设置',
      children: const [Text('字体大小'), Text('背景颜色')],
    ));

    // 打开底部弹窗
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('阅读设置'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('背景颜色'), findsOneWidget);
  });

  testWidgets('AppBottomSheet shows trailing widget', (tester) async {
    await tester.pumpWidget(buildTestWidget(
      title: '测试',
      children: const [Text('内容')],
      trailing: const Icon(Icons.close),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('AppBottomSheet can be dismissed', (tester) async {
    await tester.pumpWidget(buildTestWidget(
      title: '测试弹窗',
      children: const [Text('内容')],
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('测试弹窗'), findsOneWidget);

    // 点击外部关闭
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('测试弹窗'), findsNothing);
  });
}
