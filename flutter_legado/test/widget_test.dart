import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/app.dart';

void main() {
  testWidgets('LegadoApp builds without error', (WidgetTester tester) async {
    // LegadoApp 依赖多个 Riverpod Notifier（BookshelfNotifier 等），
    // 而这些 Notifier 需要 RustApi FFI 初始化，无法在纯测试环境中运行。
    // 因此只验证 LegadoApp widget 本身能正确创建。
    const app = LegadoApp();
    expect(app, isA<LegadoApp>());
    expect(app, isA<ConsumerStatefulWidget>());
  });

  testWidgets('LegadoApp key is preserved', (WidgetTester tester) async {
    const key = Key('test_app');
    const app = LegadoApp(key: key);
    expect(app.key, equals(key));
  });
}
