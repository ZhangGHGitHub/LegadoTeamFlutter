// [设置批2b-2b P2] 容器控制器：同入口去重、push 抛错回滚后可重试、
// 未挂载时回落 root push 由调用方处理。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/navigation/my_pane_scope.dart';

void main() {
  testWidgets('pushNamed 去重；push 抛错回滚 top/selected 后可重试', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = MyPaneController()..navigatorKey = navigatorKey;
    addTearDown(controller.dispose);
    var fail = true;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
        onGenerateRoute: (settings) {
          if (fail) throw StateError('boom');
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Center(child: Text('ok'))),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.topRoute, isNull);
    expect(controller.selectedRoute, isNull);

    // 首次 push 抛错：去重/选中态回滚，重试不会被误判为「已在栈顶」
    expect(() => controller.pushNamed('/x'), throwsStateError);
    expect(controller.topRoute, isNull);
    expect(controller.selectedRoute, isNull);

    fail = false;
    expect(controller.pushNamed('/x'), isTrue);
    expect(controller.topRoute, '/x');
    expect(controller.selectedRoute, '/x');
    await tester.pumpAndSettle();
    expect(find.text('ok'), findsOneWidget);

    // 重复点同入口：去重，不叠第二页
    expect(controller.pushNamed('/x'), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('ok'), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isTrue);
  });

  test('未挂载 nested Navigator 时 pushNamed 返回 false（调用方 root push）', () {
    final controller = MyPaneController();
    addTearDown(controller.dispose);
    expect(controller.pushNamed('/x'), isFalse);
    expect(controller.topRoute, isNull);
  });
}
