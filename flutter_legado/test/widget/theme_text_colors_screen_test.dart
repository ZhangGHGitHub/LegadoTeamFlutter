// [批13 | 2026-11-10] 主题页字体色行 widget 测试 — 全栈工程师 + UI
//
// 覆盖任务书测试项：
// - 日夜各 6 个颜色行（主色调/强调色/主要字体色/次要字体色/背景色/底栏色）；
// - 改「主要字体色」后 ColorScheme.onSurface 实际变化（真实颜色断言）；
// - 恢复默认后回落内置 palette role / 默认常量；
// - 夜间行独立写 colorMD3OnSurfaceNight，日间保持未设置；
// - 旧 themeConfigList（无字体色字段）应用不崩、按 0 处理；
// - 360dp + textScale 1.3 下新行不溢出。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/theme_colors_notifier.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';

/// 预设色板中的蓝色（kContainerColorPresets 成员）
const _pickedBlue = 0xFF2196F3;
const _pickedBlueColor = Color(_pickedBlue);

Finder _row(String key) => find.byKey(ValueKey('theme-color-$key'));

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Color? colorOrNull(int? argb) => argb == null ? null : Color(argb);

  /// 与生产 app.dart 同构：MaterialApp 的主题由 themeColorsProvider 解析，
  /// 字体色改变会真实驱动 ColorScheme 重建。
  Widget wrap({ThemeMode themeMode = ThemeMode.system}) {
    return UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          final colors = ref.watch(themeColorsProvider);
          ThemeData themeFor(Brightness brightness) => AppTheme.palette(
            brightness: brightness,
            palette: Md3Palettes.def,
            primaryTextColor: colorOrNull(
              colors.primaryTextColorFor(brightness),
            ),
            secondaryTextColor: colorOrNull(
              colors.secondaryTextColorFor(brightness),
            ),
          );
          return MaterialApp(
            theme: themeFor(Brightness.light),
            darkTheme: themeFor(Brightness.dark),
            themeMode: themeMode,
            home: const ThemeConfigScreen(),
          );
        },
      ),
    );
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    ThemeMode themeMode = ThemeMode.system,
  }) async {
    await tester.pumpWidget(wrap(themeMode: themeMode));
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byType(ListView).first,
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pickPreset(WidgetTester tester, Finder row) async {
    await scrollTo(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    // 预设色盘对话框（标题 = 行标题，色卡带稳定 Key）
    await tester.tap(
      find.byKey(const ValueKey('theme-color-preset-$_pickedBlue')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('日夜各 6 个颜色行（含主要/次要字体色）', (tester) async {
    await pumpPage(tester);

    await scrollTo(tester, find.text('自定义主题 · 白天'));
    const dayKeys = <String>[
      PrefKeys.cPrimary,
      PrefKeys.cAccent,
      PrefKeys.cPrimaryText,
      PrefKeys.cSecondaryText,
      PrefKeys.cBackground,
      PrefKeys.cBBackground,
    ];
    for (final key in dayKeys) {
      expect(_row(key), findsOneWidget, reason: '白天缺少颜色行 $key');
    }
    expect(
      find.descendant(
        of: _row(PrefKeys.cPrimaryText),
        matching: find.text('主要字体色'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row(PrefKeys.cSecondaryText),
        matching: find.text('次要字体色'),
      ),
      findsOneWidget,
    );

    await scrollTo(tester, find.text('自定义主题 · 夜间'));
    const nightKeys = <String>[
      PrefKeys.cNPrimary,
      PrefKeys.cNAccent,
      PrefKeys.cNPrimaryText,
      PrefKeys.cNSecondaryText,
      PrefKeys.cNBackground,
      PrefKeys.cNBBackground,
    ];
    for (final key in nightKeys) {
      expect(_row(key), findsOneWidget, reason: '夜间缺少颜色行 $key');
    }
  });

  testWidgets('改白天主要字体色：状态/持久化/ColorScheme 同步变化，恢复默认回退', (tester) async {
    await pumpPage(tester);
    final dayRow = _row(PrefKeys.cPrimaryText);
    await scrollTo(tester, dayRow);

    // 未设置时行显示「默认」，ColorScheme.onSurface 为内置 role
    final baseOnSurface = md3LightScheme(Md3Palettes.def).onSurface;
    expect(
      find.descendant(of: dayRow, matching: find.text('默认')),
      findsOneWidget,
    );
    expect(
      Theme.of(tester.element(dayRow)).colorScheme.onSurface,
      baseOnSurface,
    );

    await pickPreset(tester, dayRow);

    final state = container.read(themeColorsProvider);
    expect(state.primaryTextColor, _pickedBlue);
    expect(state.effectivePrimaryTextColor(Brightness.light), _pickedBlue);
    // 真实联动：页面 MaterialApp 的 ColorScheme.onSurface 变为所选颜色
    expect(
      Theme.of(tester.element(dayRow)).colorScheme.onSurface,
      _pickedBlueColor,
    );
    // 次要字体色未设置 → onSurfaceVariant 保持内置 role
    expect(
      Theme.of(tester.element(dayRow)).colorScheme.onSurfaceVariant,
      md3LightScheme(Md3Palettes.def).onSurfaceVariant,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.cPrimaryText), _pickedBlue);
    expect(
      find.descendant(of: dayRow, matching: find.text('默认')),
      findsNothing,
    );

    // 再次打开色盘 → 恢复默认（清除）
    await tester.tap(dayRow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    final cleared = container.read(themeColorsProvider);
    expect(cleared.primaryTextColor, 0);
    expect(prefs.containsKey(PrefKeys.cPrimaryText), isFalse);
    expect(
      cleared.effectivePrimaryTextColor(Brightness.light),
      ThemeColorsState.defaultPrimaryTextColor,
    );
    expect(
      Theme.of(tester.element(dayRow)).colorScheme.onSurface,
      baseOnSurface,
    );
    expect(
      find.descendant(of: dayRow, matching: find.text('默认')),
      findsOneWidget,
    );
  });

  testWidgets('改夜间主要字体色：夜间独立值生效，日间保持未设置', (tester) async {
    await pumpPage(tester, themeMode: ThemeMode.dark);
    final nightRow = _row(PrefKeys.cNPrimaryText);
    await scrollTo(tester, find.text('自定义主题 · 夜间'));
    await pickPreset(tester, nightRow);

    final state = container.read(themeColorsProvider);
    expect(state.primaryTextColorNight, _pickedBlue);
    expect(state.primaryTextColor, 0);
    expect(
      state.effectivePrimaryTextColor(Brightness.dark),
      _pickedBlue,
      reason: '夜间用独立值',
    );
    expect(
      state.effectivePrimaryTextColor(Brightness.light),
      ThemeColorsState.defaultPrimaryTextColor,
      reason: '日间未设置 → 默认常量，不继承夜间',
    );
    // 暗色 MaterialApp 的 onSurface 已被夜间字体色覆盖
    expect(
      Theme.of(tester.element(nightRow)).colorScheme.onSurface,
      _pickedBlueColor,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.cNPrimaryText), _pickedBlue);
    expect(prefs.containsKey(PrefKeys.cPrimaryText), isFalse);
  });

  testWidgets('旧 themeConfigList 无字体色字段：应用不崩且按 0 处理', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'themeConfigList': jsonEncode(<Map<String, Object>>[
        <String, Object>{
          'name': '旧白色主题',
          'isNight': false,
          'primary': 0xFF112233,
          'accent': 0xFF223344,
          'background': 0xFFF5F5F5,
          'bottomBackground': 0xFFEEEEEE,
        },
      ]),
    });
    await pumpPage(tester);

    await scrollTo(tester, find.text('主题管理'));
    await tester.tap(find.text('主题管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-config-item-0')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final state = container.read(themeColorsProvider);
    expect(state.primary, 0xFF112233);
    expect(state.primaryTextColor, 0);
    expect(state.secondaryTextColor, 0);
    expect(
      state.effectivePrimaryTextColor(Brightness.light),
      ThemeColorsState.defaultPrimaryTextColor,
    );
  });

  testWidgets('360dp + textScale 1.3：字体色行不溢出且标题不截断', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpPage(tester);
    await scrollTo(tester, find.text('自定义主题 · 白天'));

    for (final entry in <String, String>{
      PrefKeys.cPrimaryText: '主要字体色',
      PrefKeys.cSecondaryText: '次要字体色',
    }.entries) {
      final title = find.descendant(
        of: _row(entry.key),
        matching: find.text(entry.value),
      );
      expect(title, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
        isFalse,
        reason: '${entry.value} 在 360dp/1.3 下不得截断',
      );
    }
    expect(tester.takeException(), isNull);

    // 色盘对话框在窄屏 + 大字下同样不溢出
    final dayRow = _row(PrefKeys.cPrimaryText);
    await tester.tap(dayRow);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('自定义主题 · 夜间'));
    expect(_row(PrefKeys.cNPrimaryText), findsOneWidget);
    expect(_row(PrefKeys.cNSecondaryText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
