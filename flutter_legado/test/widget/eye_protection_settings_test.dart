// [设置批2a-1 | 2026-11-01] 外观设置页「护眼模式」分组交互测试
// — 全栈工程师
//
// 覆盖：分组渲染/默认值、开关展开/收起、定时时间行、时间选择器入口、
// 色温滑杆落盘、开关状态写入 SharedPreferences。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.resetStatic();
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

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byType(ListView),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('护眼模式分组默认值：两开关关闭，强度/定时行隐藏', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('护眼模式'));

    expect(find.text('护眼模式'), findsOneWidget);
    expect(find.text('启用护眼模式'), findsOneWidget);
    expect(find.text('深色模式时自动开启'), findsOneWidget);
    expect(find.text('色温'), findsNothing, reason: '未配置时（总开关与自动夜间均关）不显示强度行');
    expect(find.text('定时开启'), findsNothing);
    expect(find.text('开始时间'), findsNothing);
  });

  testWidgets('启用开关展开色温与定时；再关闭收起', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('启用护眼模式'));

    await tester.tap(find.text('启用护眼模式'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('色温'));

    expect(find.text('色温'), findsOneWidget);
    expect(find.text('当前色温：50'), findsOneWidget);
    expect(find.text('定时开启'), findsOneWidget);
    expect(find.text('开始时间'), findsNothing, reason: '定时未开启时不显示时间行');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.eyeProtectionEnabled), isTrue);

    // 关闭总开关（自动夜间仍关）→ 行收起
    await scrollTo(tester, find.text('启用护眼模式'));
    await tester.tap(find.text('启用护眼模式'));
    await tester.pumpAndSettle();
    expect(find.text('色温'), findsNothing);
    expect(prefs.getBool(PrefKeys.eyeProtectionEnabled), isFalse);
  });

  testWidgets('深色模式时自动开启也可展开配置行（参考 isConfigured 语义）', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('深色模式时自动开启'));

    await tester.tap(find.text('深色模式时自动开启'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('色温'));

    expect(find.text('色温'), findsOneWidget);
    expect(find.text('定时开启'), findsOneWidget);
  });

  testWidgets('定时开启显示起止默认值，点击行打开 24 小时时间选择器', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('启用护眼模式'));
    await tester.tap(find.text('启用护眼模式'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('定时开启'));
    await tester.tap(find.text('定时开启'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('开始时间'));

    expect(find.text('开始时间'), findsOneWidget);
    expect(find.text('结束时间'), findsOneWidget);
    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('07:00'), findsOneWidget);

    await tester.tap(find.text('开始时间'));
    await tester.pumpAndSettle();
    expect(
      find.byType(TimePickerDialog),
      findsOneWidget,
      reason: '点击开始时间应打开 24 小时制时间选择器',
    );

    // 关闭时间选择器（不改变值）
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.eyeProtectionSchedule), isTrue);
  });

  testWidgets('色温滑杆松手落盘 colorTemperature 键', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('启用护眼模式'));
    await tester.tap(find.text('启用护眼模式'));
    await tester.pumpAndSettle();
    await scrollTo(
      tester,
      find.byKey(const ValueKey<String>('eyeProtectionIntensitySlider')),
    );

    final slider = find.byKey(
      const ValueKey<String>('eyeProtectionIntensitySlider'),
    );
    await tester.drag(slider, const Offset(200, 0));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(PrefKeys.colorTemperature);
    expect(value, isNotNull);
    expect(value, greaterThan(50), reason: '向右拖动应增大色温强度');
    expect(find.text('当前色温：$value'), findsOneWidget);
  });
}
