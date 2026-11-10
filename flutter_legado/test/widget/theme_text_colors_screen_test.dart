// [批13 | 2026-11-10] 主题页字体色行 widget 测试 — 全栈工程师 + UI
//
// 覆盖任务书测试项：
// - 日夜各 6 个颜色行（主色调/强调色/主要字体色/次要字体色/背景色/底栏色）；
// - 改「主要字体色」后 ColorScheme 与正文 Text 实际渲染颜色同步变化
//   （RenderParagraph 合并后的样式，真实颜色断言）；
// - 恢复默认后回落内置 palette role / 默认常量；
// - [审查回修] 清除夜间字体色后回落继承日间；保存白天主题→应用时
//   字体色字段真实往返；
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

/// 取 Text 实际渲染的解析后颜色（RenderParagraph 合并 DefaultTextStyle 后）
Color? _renderedTextColor(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final span = paragraph.text;
  return span is TextSpan ? span.style?.color : null;
}

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Color? colorOrNull(int? argb) =>
      argb != null && argb != 0 ? Color(argb) : null;

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

  testWidgets('改白天主要字体色：状态/持久化/ColorScheme/正文 Text 同步变化，恢复默认回退', (
    tester,
  ) async {
    await pumpPage(tester);
    final dayRow = _row(PrefKeys.cPrimaryText);
    final titleFinder = find.descendant(
      of: dayRow,
      matching: find.text('主要字体色'),
    );
    await scrollTo(tester, dayRow);

    // 未设置时行显示「默认」，ColorScheme.onSurface 为内置 role，
    // 行标题正文实际渲染颜色也是 onSurface
    final baseOnSurface = md3LightScheme(Md3Palettes.def).onSurface;
    expect(
      find.descendant(of: dayRow, matching: find.text('默认')),
      findsOneWidget,
    );
    expect(
      Theme.of(tester.element(dayRow)).colorScheme.onSurface,
      baseOnSurface,
    );
    expect(_renderedTextColor(tester, titleFinder), baseOnSurface);

    await pickPreset(tester, dayRow);

    final state = container.read(themeColorsProvider);
    expect(state.primaryTextColor, _pickedBlue);
    expect(state.effectivePrimaryTextColor(Brightness.light), _pickedBlue);
    // 真实联动：页面 MaterialApp 的 ColorScheme.onSurface 变为所选颜色
    expect(
      Theme.of(tester.element(dayRow)).colorScheme.onSurface,
      _pickedBlueColor,
    );
    // 正文 Text 实际渲染颜色同样改变（RenderParagraph 解析后的 style）
    expect(_renderedTextColor(tester, titleFinder), _pickedBlueColor);
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
    expect(_renderedTextColor(tester, titleFinder), baseOnSurface);
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

  // ===== [审查回修] 夜间清除回落 + 保存/应用真实往返 =====

  testWidgets('清除夜间主要字体色 → 暗色回落继承日间（非默认常量）', (tester) async {
    const dayColor = 0xFF112233;
    await pumpPage(tester, themeMode: ThemeMode.dark);
    final notifier = container.read(themeColorsProvider.notifier);
    await notifier.applyColors(<String, int?>{
      PrefKeys.cPrimaryText: dayColor,
      PrefKeys.cNPrimaryText: _pickedBlue,
    });
    await tester.pumpAndSettle();

    final nightRow = _row(PrefKeys.cNPrimaryText);
    await scrollTo(tester, find.text('自定义主题 · 夜间'));
    expect(
      Theme.of(tester.element(nightRow)).colorScheme.onSurface,
      _pickedBlueColor,
      reason: '夜间独立值优先',
    );

    await tester.tap(nightRow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    final state = container.read(themeColorsProvider);
    expect(state.primaryTextColorNight, 0);
    expect(state.primaryTextColor, dayColor, reason: '日间值不得被清除');
    expect(state.primaryTextColorFor(Brightness.dark), dayColor);
    expect(
      state.effectivePrimaryTextColor(Brightness.dark),
      dayColor,
      reason: '夜间清除后逐字段继承日间，而不是回落默认常量',
    );
    expect(
      Theme.of(tester.element(nightRow)).colorScheme.onSurface,
      const Color(dayColor),
    );
  });

  testWidgets('保存白天主题 → 修改后应用：字体色字段真实往返', (tester) async {
    const savedPrimaryText = 0xFF2196F3;
    const savedSecondaryText = 0xFF445566;
    await pumpPage(tester);
    final notifier = container.read(themeColorsProvider.notifier);
    await notifier.applyColors(<String, int?>{
      PrefKeys.cPrimaryText: savedPrimaryText,
      PrefKeys.cSecondaryText: savedSecondaryText,
    });
    await tester.pumpAndSettle();

    // 保存当前白天配色
    await scrollTo(tester, find.text('保存白天主题'));
    await tester.tap(find.text('保存白天主题'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '字体色往返',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final stored =
        (jsonDecode(prefs.getString('themeConfigList')!) as List).single
            as Map<String, dynamic>;
    expect(stored['name'], '字体色往返');
    expect(stored['isNight'], isFalse);
    expect(stored['primaryText'], savedPrimaryText);
    expect(stored['secondaryText'], savedSecondaryText);

    // 清空后应用保存项，字体色必须从 JSON 真实回填
    await notifier.applyColors(<String, int?>{
      PrefKeys.cPrimaryText: null,
      PrefKeys.cSecondaryText: null,
    });
    await tester.pumpAndSettle();
    expect(container.read(themeColorsProvider).primaryTextColor, 0);

    await tester.dragUntilVisible(
      find.text('主题管理'),
      find.byType(ListView).first,
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-config-item-0')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final applied = container.read(themeColorsProvider);
    expect(applied.primaryTextColor, savedPrimaryText);
    expect(applied.secondaryTextColor, savedSecondaryText);
    expect(
      Theme.of(tester.element(find.text('外观'))).colorScheme.onSurface,
      const Color(savedPrimaryText),
    );
  });
}
