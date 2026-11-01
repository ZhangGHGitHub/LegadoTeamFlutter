// [设置批2a-1 | 2026-11-01] 外观设置页「护眼模式」分组交互测试
// — 全栈工程师
//
// 覆盖：分组渲染/默认值、开关展开/收起、定时时间行、24 小时时间选择器、
// 色温滑杆落盘、开关状态写入 SharedPreferences；阅读设置页入口打开同一面板。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/screens/read_config_screen.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/widgets/eye_protection_config_sheet.dart';

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
    // 24 小时制断言：TimePicker 子树内 alwaysUse24HourFormat=true，且无 AM/PM
    final pickerContext = tester.element(find.byType(TimePickerDialog));
    expect(MediaQuery.of(pickerContext).alwaysUse24HourFormat, isTrue);
    expect(find.text('AM'), findsNothing);
    expect(find.text('PM'), findsNothing);

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

  // [P2-2] 阅读设置页入口：与外观页共用同一面板/Notifier
  testWidgets('阅读设置页「护眼模式」行打开同一面板并即时写回', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReadConfigScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('护眼模式'),
      find.byType(ListView),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(find.text('护眼模式'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);
    // 参考版 ReadConfigScreen 顺序：护眼模式（#14）在亮度条模式（#15）之前
    expect(
      tester.getTopLeft(find.text('护眼模式')).dy,
      lessThan(tester.getTopLeft(find.text('亮度条模式')).dy),
    );

    await tester.tap(find.text('护眼模式'));
    await tester.pumpAndSettle();
    expect(find.byType(EyeProtectionConfigPanel), findsOneWidget);
    expect(find.text('启用护眼模式'), findsOneWidget);

    await tester.tap(find.text('启用护眼模式'));
    await tester.pumpAndSettle();
    // 阅读侧面板文案：护眼强度 / 当前强度（外观页仍是 色温 / 当前色温）
    expect(find.text('护眼强度'), findsOneWidget);
    expect(find.text('当前强度：50'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.eyeProtectionEnabled), isTrue);

    // 关闭面板：行尾状态由同一 Notifier 驱动即时变为「已启用」
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(EyeProtectionConfigPanel), findsNothing);
    expect(find.text('已启用'), findsOneWidget);
  });
}
