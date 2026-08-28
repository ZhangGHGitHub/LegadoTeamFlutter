// 主题配置页 widget 测试
//
// 对齐 2026-08-13：主题模式仅在「我的」枢纽；本页保留通用项 + 白天/夜间。
// [MD3 Batch 1] 新增「内置主题」12 套调色板选择网格（UI_MD3_PLAN.md），
// 通用项位于网格之下，断言前需滚动到可见区；「白天/夜间」更名为
// 「自定义主题 · 白天/夜间」（与内置主题并存的双区结构）。
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

  testWidgets('渲染内置主题网格/通用项与自定义主题分组', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 内置主题网格置顶：默认 WH 选中（12 套，纯白在列）
    expect(find.text('内置主题'), findsOneWidget);
    expect(find.text('纯白'), findsOneWidget);
    expect(find.text('小春'), findsOneWidget);
    expect(find.text('墨水'), findsOneWidget);

    // 通用项位于内置主题网格下方，滚动到可见区再断言
    await tester.dragUntilVisible(find.text(r'切换图标'), find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('切换图标'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('底栏图集'), findsOneWidget);

    await tester.dragUntilVisible(find.text(r'自定义主题 · 白天'), find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题 · 白天'), findsOneWidget);

    await tester.dragUntilVisible(find.text(r'自定义主题 · 夜间'), find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题 · 夜间'), findsOneWidget);

    // 页内主题模式 SegmentedButton 已移除
    expect(find.text('主题模式'), findsNothing);
  });

  testWidgets('内置主题网格点按切换调色板并更新 ThemeState', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 默认调色板为 WH（纯白）
    expect(container.read(themeNotifierProvider).paletteId, equals('wh'));

    // 点按「小春」（koharu）→ paletteId 更新并持久化
    await tester.tap(find.text('小春'));
    await tester.pumpAndSettle();
    expect(
      container.read(themeNotifierProvider).paletteId,
      equals('koharu'),
    );
  });

  testWidgets('字体大小对话框可设置倍数并跟随系统重置', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 字体大小项在内置主题网格下方，先滚动到可见区
    await tester.dragUntilVisible(find.text(r'字体大小'), find.byType(ListView), const Offset(0, -120));
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
