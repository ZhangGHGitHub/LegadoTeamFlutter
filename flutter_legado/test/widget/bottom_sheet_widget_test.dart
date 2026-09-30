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

  // [统一壳 B2a] 迁移形态用例：标题 + 操作 ListTile 列表（主题选择/底栏皮肤/
  // 书源操作三处迁移后的共同形态），点击 ListTile 以返回值关闭。
  testWidgets('AppBottomSheet 列表操作项返回值（迁移形态）', (tester) async {
    String? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  action = await AppBottomSheet.show<String>(
                    context: context,
                    title: '测试书源',
                    children: [
                      ListTile(
                        leading: const Icon(Icons.arrow_upward),
                        title: const Text('置顶'),
                        onTap: () => Navigator.pop(context, 'top'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.delete),
                        title: const Text('删除'),
                        onTap: () => Navigator.pop(context, 'delete'),
                      ),
                    ],
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('测试书源'), findsOneWidget);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(action, 'delete');
    expect(find.text('测试书源'), findsNothing);
  });
}
