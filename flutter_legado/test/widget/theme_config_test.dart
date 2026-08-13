// 主题配置页 widget 测试
//
// 对齐 2026-08-13：主题模式仅在「我的」枢纽；本页保留通用项 + 白天/夜间。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ThemeConfigScreen()),
    );
  }

  testWidgets('渲染通用项与白天/夜间分组（无页内主题模式）', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('切换图标'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('底栏图集'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('白天'), 80);
    await tester.pumpAndSettle();
    expect(find.text('白天'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('夜间'), 80);
    await tester.pumpAndSettle();
    expect(find.text('夜间'), findsOneWidget);

    // 页内主题模式 SegmentedButton 已移除
    expect(find.text('主题模式'), findsNothing);
  });

  testWidgets('字体大小对话框可设置倍数并跟随系统重置', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('字体大小'));
    await tester.pumpAndSettle();
    expect(find.text('字体缩放'), findsOneWidget);
    expect(find.text('当前字体大小：1.0'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('确定'),
    ));
    await tester.pumpAndSettle();
    var state = container.read(themeNotifierProvider);
    expect(state.fontScaleRaw, equals(10));
    expect(state.fontScale, equals(1.0));
    expect(state.fontScaleLabel, equals('当前字体大小：1.0'));

    await tester.tap(find.text('字体大小'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '跟随系统'),
    ));
    await tester.pumpAndSettle();
    state = container.read(themeNotifierProvider);
    expect(state.fontScaleRaw, equals(0));
    expect(state.fontScale, isNull);
  });
}
