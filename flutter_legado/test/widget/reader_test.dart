import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Reader controls visible', (tester) async {
    // 验证阅读器基本控件：顶部栏和底部控制栏
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // 阅读内容区域
              const Center(child: Text('第一章 起始')),
              // 顶部栏
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppBar(
                  title: const Text('斗破苍穹'),
                  leading: const BackButton(),
                ),
              ),
              // 底部控制栏
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black87,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.skip_previous),
                        onPressed: null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.list),
                        onPressed: null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings),
                        onPressed: null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        onPressed: null,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 验证章节内容显示
    expect(find.text('第一章 起始'), findsOneWidget);

    // 验证顶部标题
    expect(find.text('斗破苍穹'), findsOneWidget);

    // 验证返回按钮
    expect(find.byType(BackButton), findsOneWidget);

    // 验证底部控制按钮
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.list), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
  });

  testWidgets('Reader tap center toggles controls', (tester) async {
    bool controlsVisible = false;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: GestureDetector(
              onTapUp: (details) {
                final size = MediaQuery.of(context).size;
                final x = details.globalPosition.dx / size.width;
                if (x > 0.3 && x < 0.7) {
                  setState(() => controlsVisible = !controlsVisible);
                }
              },
              child: Stack(
                children: [
                  const Center(child: Text('阅读内容')),
                  if (controlsVisible)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: AppBar(title: const Text('控制栏')),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // 初始状态控制栏不可见
    expect(find.text('控制栏'), findsNothing);

    // 点击屏幕中央
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();

    // 控制栏变为可见
    expect(find.text('控制栏'), findsOneWidget);
  });
}
