// [2b-2c 复核] Md3FastScroller 多 position 防御
//
// 设备验收缺陷：宽屏发现「源列表+分类书单」双栏点书后，发现页宽度跌破
// 840dp 触发内部布局切换；同一 ScrollController 的旧/新 ScrollPosition
// 短暂并存，`ScrollController.position` 断言 `Too many elements`。
// 本套件覆盖：
// - 同一 controller 挂两个 ScrollView 时不崩溃，滑块只驱动本组件子树；
// - 布局切换过渡帧（Row → 直接子级）同一 controller 不崩溃。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/md3_fast_scroller.dart';

Widget _list(ScrollController controller, String prefix) {
  return ListView.builder(
    controller: controller,
    itemCount: 40,
    itemBuilder: (_, index) => SizedBox(
      height: 48,
      child: Text('$prefix$index'),
    ),
  );
}

void main() {
  testWidgets('同一 controller 两个 ScrollView：不触发 position 断言，滑块只驱动本子树', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: Md3FastScroller(
                  controller: controller,
                  child: _list(controller, 'A'),
                ),
              ),
              Expanded(child: _list(controller, 'B')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.positions.length, 2);
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);

    // 本组件子树（A）与另一列（B）分别持有一个 position
    final aPosition = tester
        .stateList<ScrollableState>(
          find.descendant(
            of: find.byType(Md3FastScroller),
            matching: find.byType(Scrollable),
          ),
        )
        .first
        .position;
    final bPosition = tester
        .stateList<ScrollableState>(
          find.descendant(of: find.byType(Row), matching: find.byType(Scrollable)),
        )
        .last
        .position;
    expect(aPosition, isNot(same(bPosition)));

    // 拖拽滑块：使用本子树 position，另一列不动
    final thumb = find
        .descendant(
          of: find.byType(Md3FastScroller),
          matching: find.byType(GestureDetector),
        )
        .first;
    expect(thumb, findsOneWidget);
    await tester.drag(thumb, const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(aPosition.pixels, greaterThan(0));
    expect(bPosition.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('布局切换过渡帧（Row → 直接子级）：同一 controller 不崩溃', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var split = true;
    late StateSetter setOuter;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            final scroller = Md3FastScroller(
              controller: controller,
              child: _list(controller, 'A'),
            );
            return Scaffold(
              body: split
                  ? Row(
                      children: [
                        Expanded(child: scroller),
                        const Expanded(child: SizedBox.shrink()),
                      ],
                    )
                  : scroller,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    setOuter(() => split = false);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
  });
}
