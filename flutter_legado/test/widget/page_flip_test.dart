import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/page_flip_widget.dart';

void main() {
  // ===== SimulationPageFlipWidget 测试 =====

  testWidgets('SimulationPageFlipWidget 基本构建', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimulationPageFlipWidget(
            currentBuilder: (_) => const Center(child: Text('当前页')),
            nextBuilder: (_) => const Center(child: Text('下一页')),
            prevBuilder: (_) => const Center(child: Text('上一页')),
          ),
        ),
      ),
    );

    // 验证当前页内容显示
    expect(find.text('当前页'), findsOneWidget);
  });

  testWidgets('SimulationPageFlipWidget 显示当前页 builder 内容', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimulationPageFlipWidget(
            currentBuilder: (_) => const Center(
              child: Text('第一章 起始之章', style: TextStyle(fontSize: 18)),
            ),
            nextBuilder: (_) => const Center(child: Text('第二章')),
            prevBuilder: (_) => const Center(child: Text('序章')),
          ),
        ),
      ),
    );

    expect(find.text('第一章 起始之章'), findsOneWidget);
    expect(find.text('序章'), findsNothing);
    expect(find.text('第二章'), findsNothing);
  });

  testWidgets('SimulationPageFlipWidget 自定义动画时长', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimulationPageFlipWidget(
            currentBuilder: (_) => const Center(child: Text('当前页')),
            nextBuilder: (_) => const Center(child: Text('下一页')),
            prevBuilder: (_) => const Center(child: Text('上一页')),
            animDuration: const Duration(milliseconds: 300),
          ),
        ),
      ),
    );

    final widget = tester.widget<SimulationPageFlipWidget>(
      find.byType(SimulationPageFlipWidget),
    );
    expect(widget.animDuration, equals(const Duration(milliseconds: 300)));
  });

  testWidgets('SimulationPageFlipWidget onPageTurned 回调可设置', (tester) async {
    int? turnedDirection;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimulationPageFlipWidget(
            currentBuilder: (_) => const Center(child: Text('当前页')),
            nextBuilder: (_) => const Center(child: Text('下一页')),
            prevBuilder: (_) => const Center(child: Text('上一页')),
            onPageTurned: (dir) => turnedDirection = dir,
          ),
        ),
      ),
    );

    final widget = tester.widget<SimulationPageFlipWidget>(
      find.byType(SimulationPageFlipWidget),
    );
    expect(widget.onPageTurned, isNotNull);
    expect(turnedDirection, isNull); // 未翻页时为 null
  });

  testWidgets('SimulationPageFlipWidget 填满父容器', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: SimulationPageFlipWidget(
              currentBuilder: (_) => const Center(child: Text('当前页')),
              nextBuilder: (_) => const Center(child: Text('下一页')),
              prevBuilder: (_) => const Center(child: Text('上一页')),
            ),
          ),
        ),
      ),
    );

    // SimulationPageFlipWidget 使用 LayoutBuilder，应填满 SizedBox
    final renderBox = tester.renderObject<RenderBox>(
      find.byType(SimulationPageFlipWidget),
    );
    expect(renderBox.size.width, equals(400));
    expect(renderBox.size.height, equals(600));
  });

  testWidgets('SimulationPageFlipWidget GestureDetector 可拖拽', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: SimulationPageFlipWidget(
              currentBuilder: (_) => const Center(child: Text('当前页')),
              nextBuilder: (_) => const Center(child: Text('下一页')),
              prevBuilder: (_) => const Center(child: Text('上一页')),
            ),
          ),
        ),
      ),
    );

    // 验证 GestureDetector 存在（仿真翻页依赖手势）
    expect(find.byType(GestureDetector), findsWidgets);

    // 模拟拖拽不会崩溃
    await tester.drag(
      find.byType(SimulationPageFlipWidget),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();

    // 拖拽后当前页仍在
    expect(find.text('当前页'), findsOneWidget);
  });

  // ===== 滑动翻页（SlidePage）测试 =====

  testWidgets('滑动翻页 PageView 基本构建', (tester) async {
    final pageController = PageController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView.builder(
            controller: pageController,
            itemCount: 3,
            itemBuilder: (context, index) {
              return Center(child: Text('第 ${index + 1} 页'));
            },
          ),
        ),
      ),
    );

    // 默认显示第一页
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('第 2 页'), findsNothing);
  });

  testWidgets('滑动翻页 PageView 可滑动到下一页', (tester) async {
    final pageController = PageController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView.builder(
            controller: pageController,
            itemCount: 3,
            itemBuilder: (context, index) {
              return Center(child: Text('第 ${index + 1} 页'));
            },
          ),
        ),
      ),
    );

    // 向左滑动到下一页
    await tester.fling(
      find.byType(PageView),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.text('第 2 页'), findsOneWidget);
    expect(pageController.page, equals(1));
  });
}
