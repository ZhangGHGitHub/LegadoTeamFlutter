// [设置批2b-1b-1 | 2026-11-01] 外观页「容器设置」圆角/边框/分隔线交互测试 — 全栈工程师
//
// 覆盖：默认行显隐（滑杆/颜色行按开关条件显示）、开关落盘并即时推送、
// 圆角/边框宽度/分隔线宽度与长度滑杆落盘、日/夜边框颜色与分隔线颜色
// 色板选择及恢复默认、禁用分组圆角开关。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/setting_slider_row.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    uiSettingsListenable.value = const UiSettingsState();
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  Widget wrap() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ThemeConfigScreen()),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
  }

  Finder sliderRow(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(SettingSliderRow),
  );

  Finder sliderOf(String title) =>
      find.descendant(of: sliderRow(title), matching: find.byType(Slider));

  Future<void> tapSwitch(WidgetTester tester, String title) async {
    await scrollTo(tester, find.text(title));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('默认：四项开关渲染，条件行隐藏', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器设置'));

    expect(find.text('关闭设置分组圆角'), findsOneWidget);
    expect(find.text('覆盖卡片圆角'), findsOneWidget);
    expect(find.text('覆盖卡片边框'), findsOneWidget);
    expect(find.text('显示分隔线'), findsOneWidget);

    // 开关默认关 → 滑杆/颜色行不渲染
    expect(find.text('卡片圆角'), findsNothing);
    expect(find.text('边框宽度'), findsNothing);
    expect(find.text('日间边框颜色'), findsNothing);
    expect(find.text('夜间边框颜色'), findsNothing);
    expect(find.text('分隔线宽度'), findsNothing);
    expect(find.text('分隔线长度'), findsNothing);
    expect(find.text('分隔线颜色'), findsNothing);

    final switches = tester
        .widgetList<SettingSwitchRow>(find.byType(SettingSwitchRow))
        .toList();
    final byTitle = {for (final s in switches) s.title: s};
    expect(byTitle['关闭设置分组圆角']!.value, isFalse);
    expect(byTitle['覆盖卡片圆角']!.value, isFalse);
    expect(byTitle['覆盖卡片边框']!.value, isFalse);
    expect(byTitle['显示分隔线']!.value, isFalse);
  });

  testWidgets('开关落盘并即时显示条件行', (tester) async {
    await pumpPage(tester);
    final prefs = await SharedPreferences.getInstance();
    final notifier = container.read(uiSettingsProvider.notifier);

    await tapSwitch(tester, '关闭设置分组圆角');
    expect(
      prefs.getBool(PrefKeys.disableSplicedColumnGroupCornerRadius),
      isTrue,
    );
    expect(
      uiSettingsListenable.value.disableSplicedColumnGroupCornerRadius,
      isTrue,
    );

    await tapSwitch(tester, '覆盖卡片圆角');
    expect(prefs.getBool(PrefKeys.overrideBaseCardCornerRadius), isTrue);
    expect(uiSettingsListenable.value.overrideBaseCardCornerRadius, isTrue);
    await scrollTo(tester, find.text('卡片圆角'));
    expect(find.text('卡片圆角'), findsOneWidget);
    expect(find.text('16dp'), findsOneWidget);

    await tapSwitch(tester, '覆盖卡片边框');
    expect(prefs.getBool(PrefKeys.overrideBaseCardBorder), isTrue);
    await scrollTo(tester, find.text('日间边框颜色'));
    expect(find.text('边框宽度'), findsOneWidget);
    expect(find.text('1dp'), findsWidgets);
    expect(find.text('日间边框颜色'), findsOneWidget);
    expect(find.text('夜间边框颜色'), findsOneWidget);

    await tapSwitch(tester, '显示分隔线');
    expect(prefs.getBool(PrefKeys.enableItemDivider), isTrue);
    await scrollTo(tester, find.text('分隔线颜色'));
    expect(find.text('分隔线宽度'), findsOneWidget);
    expect(find.text('分隔线长度'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('分隔线颜色'), findsOneWidget);

    // 关闭后隐藏但保留值
    await tapSwitch(tester, '显示分隔线');
    expect(prefs.getBool(PrefKeys.enableItemDivider), isFalse);
    expect(notifier.state.itemDividerLength, 80);
    await scrollTo(tester, find.text('显示分隔线'));
    expect(find.text('分隔线宽度'), findsNothing);
  });

  testWidgets('滑杆：圆角/边框宽度/分隔线宽度/长度落盘与钳制', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.overrideBaseCardCornerRadius: true,
      PrefKeys.overrideBaseCardBorder: true,
      PrefKeys.enableItemDivider: true,
    });
    await container.read(uiSettingsProvider.notifier).reload();
    await pumpPage(tester);
    final prefs = await SharedPreferences.getInstance();

    await scrollTo(tester, find.text('卡片圆角'));
    var rect = tester.getRect(sliderOf('卡片圆角'));
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.baseCardCornerRadius), 40);
    expect(container.read(uiSettingsProvider).baseCardCornerRadius, 40);

    await scrollTo(tester, find.text('边框宽度'));
    rect = tester.getRect(sliderOf('边框宽度'));
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.baseCardBorderWidth), 5);

    await scrollTo(tester, find.text('分隔线宽度'));
    rect = tester.getRect(sliderOf('分隔线宽度'));
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.itemDividerWidth), 5);

    await scrollTo(tester, find.text('分隔线长度'));
    rect = tester.getRect(sliderOf('分隔线长度'));
    await tester.tapAt(Offset(rect.left + 2, rect.center.dy));
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.itemDividerLength), 30);
    expect(container.read(uiSettingsProvider).itemDividerLength, 30);
  });

  testWidgets('边框日/夜颜色：色板选择落盘，恢复默认写 0', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.overrideBaseCardBorder: true,
    });
    await container.read(uiSettingsProvider.notifier).reload();
    await pumpPage(tester);
    final prefs = await SharedPreferences.getInstance();

    Finder preset(Color color) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == color,
      ),
    );

    await scrollTo(tester, find.text('日间边框颜色'));
    await tester.tap(find.text('日间边框颜色'));
    await tester.pumpAndSettle();
    expect(find.text('恢复默认'), findsOneWidget);
    await tester.tap(preset(const Color(0xFFD32F2F)).first);
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.baseCardBorderColor), 0xFFD32F2F);
    expect(container.read(uiSettingsProvider).baseCardBorderColor, 0xFFD32F2F);

    await scrollTo(tester, find.text('日间边框颜色'));
    await tester.tap(find.text('日间边框颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.baseCardBorderColor), 0);
    expect(container.read(uiSettingsProvider).baseCardBorderColor, 0);

    await scrollTo(tester, find.text('夜间边框颜色'));
    await tester.tap(find.text('夜间边框颜色'));
    await tester.pumpAndSettle();
    await tester.tap(preset(const Color(0xFF2196F3)).first);
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.baseCardBorderColorNight), 0xFF2196F3);
  });

  testWidgets('分隔线颜色：色板选择落盘，恢复默认写 0', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.enableItemDivider: true,
    });
    await container.read(uiSettingsProvider.notifier).reload();
    await pumpPage(tester);
    final prefs = await SharedPreferences.getInstance();

    await scrollTo(tester, find.text('分隔线颜色'));
    await tester.tap(find.text('分隔线颜色'));
    await tester.pumpAndSettle();
    final target = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == const Color(0xFF4CAF50),
      ),
    );
    await tester.tap(target.first);
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.itemDividerColor), 0xFF4CAF50);
    expect(container.read(uiSettingsProvider).itemDividerColor, 0xFF4CAF50);

    await scrollTo(tester, find.text('分隔线颜色'));
    await tester.tap(find.text('分隔线颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(prefs.getInt(PrefKeys.itemDividerColor), 0);
  });
}
