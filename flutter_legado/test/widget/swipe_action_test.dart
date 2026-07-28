import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/swipe_action.dart';

void main() {
  Widget buildTestWidget({
    List<SwipeActionItem>? actions,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            SizedBox(
              height: 60,
              child: SwipeAction(
                actions: actions ??
                    [
                      SwipeActionItem(
                        label: '删除',
                        icon: Icons.delete,
                        color: Colors.red,
                        onTap: () {},
                      ),
                    ],
                child: Container(
                  color: Colors.white,
                  child: const ListTile(title: Text('测试项目')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('SwipeAction renders child widget', (tester) async {
    await tester.pumpWidget(buildTestWidget());

    expect(find.text('测试项目'), findsOneWidget);
    expect(find.byType(SwipeAction), findsOneWidget);
  });

  testWidgets('SwipeAction renders action buttons', (tester) async {
    await tester.pumpWidget(buildTestWidget(
      actions: [
        SwipeActionItem(
          label: '删除',
          icon: Icons.delete,
          color: Colors.red,
          onTap: () {},
        ),
        SwipeActionItem(
          label: '编辑',
          icon: Icons.edit,
          color: Colors.blue,
          onTap: () {},
        ),
      ],
    ));

    expect(find.text('删除'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.byIcon(Icons.delete), findsOneWidget);
    expect(find.byIcon(Icons.edit), findsOneWidget);
  });

  testWidgets('SwipeAction has GestureDetector for swipe', (tester) async {
    await tester.pumpWidget(buildTestWidget());

    expect(find.byType(GestureDetector), findsWidgets);
  });
}
