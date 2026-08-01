// 主题配置页 widget 测试
//
// 验证 Phase 5.4 provider→Riverpod 迁移后的主题切换 + 全局字体缩放 UI：
// - 主题模式 SegmentedButton（跟随系统/浅色/深色）切换驱动 ThemeNotifier
// - 全局字体缩放入口与选择对话框（对齐原版 fontScale：0.8x~1.6x + 跟随系统）
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

  testWidgets('渲染主题模式选择器与全局字体缩放入口', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 主题模式 SegmentedButton
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);

    // 全局字体缩放入口（默认跟随系统：SegmentedButton + fontScaleLabel 各一处）
    expect(find.text('全局字体大小'), findsOneWidget);
    expect(find.text('字体缩放'), findsOneWidget);
    expect(find.text('跟随系统'), findsNWidgets(2));
  });

  testWidgets('点击浅色按钮切换主题模式（驱动 ThemeNotifier）', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(container.read(themeNotifierProvider).themeMode, ThemeMode.system);

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();

    expect(container.read(themeNotifierProvider).themeMode, ThemeMode.light);
  });

  testWidgets('字体缩放对话框可设置倍数并跟随系统重置', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 打开字体缩放对话框（跟随系统时默认展示 1.0x）
    await tester.tap(find.text('字体缩放'));
    await tester.pumpAndSettle();
    expect(find.text('当前字体大小：1.0'), findsOneWidget);

    // 确定 → raw 10（1.0x）（限定对话框内，避免与页面按钮歧义）
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('确定'),
    ));
    await tester.pumpAndSettle();
    var state = container.read(themeNotifierProvider);
    expect(state.fontScaleRaw, equals(10));
    expect(state.fontScale, equals(1.0));
    expect(state.fontScaleLabel, equals('当前字体大小：1.0'));

    // 再次打开并选择「跟随系统」→ 重置为 0
    await tester.tap(find.text('字体缩放'));
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
