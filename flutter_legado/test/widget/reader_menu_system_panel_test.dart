// [批3a] 阅读器菜单系统设置面板测试（全局/底栏布局/顶栏布局）
//
// 覆盖：三段 Tab 切换、工具栏样式/调色板/颜色来源条件显示、
// 8 行日夜颜色与取色落盘、底栏滑块/开关落盘、顶栏胶囊/标题模式/
// 图标样式/合并按钮落盘。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/screens/reader_menu_system_panel.dart';
import 'package:flutter_legado/src/widgets/container_color_dialog.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap() => const ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: ReaderMenuSystemPanel()),
      ),
    ),
  );

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump();
  }

  Future<void> selectDropdown(
    WidgetTester tester,
    Key dropdownKey,
    String option,
  ) async {
    await tester.ensureVisible(find.byKey(dropdownKey));
    await tester.tap(find.byKey(dropdownKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Key colorRow(String name) => ValueKey('reader-menu-color-$name');

  testWidgets('三段 Tab 切换：全局 / 底栏布局 / 顶栏布局', (tester) async {
    await pumpPanel(tester);

    expect(find.text('全局'), findsOneWidget);
    expect(find.text('底栏布局'), findsOneWidget);
    expect(find.text('顶栏布局'), findsOneWidget);

    // [批3a P2-8] 全局默认（readBarStyle=1 跟随阅读背景）：不显示调色板
    // （1 档取种映射留 3b），也不显示颜色来源
    expect(
      find.byKey(const ValueKey('reader-menu-style-dropdown')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-menu-palette-dropdown')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('reader-menu-color-mode-dropdown')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('reader-menu-tab-1')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('reader-menu-icon-text-switch')),
      findsOneWidget,
    );
    expect(find.text('每行图标数'), findsOneWidget);
    expect(find.text('工具栏样式'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reader-menu-tab-2')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('reader-menu-title-capsule-switch')),
      findsOneWidget,
    );
    expect(find.text('合并顶栏按钮'), findsOneWidget);
    expect(find.text('每行图标数'), findsNothing);
  });

  testWidgets('工具栏样式=自定义：颜色来源切换种子/自定义，自定义显示 8 行日夜色', (tester) async {
    await pumpPanel(tester);

    await selectDropdown(
      tester,
      const ValueKey('reader-menu-style-dropdown'),
      '自定义',
    );
    expect(
      find.byKey(const ValueKey('reader-menu-color-mode-dropdown')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-menu-palette-dropdown')),
      findsNothing,
      reason: '自定义主题色模式不显示调色板',
    );

    // 默认 colorMode=1（自定义主题色）→ 8 行颜色
    for (final name in [
      'bg-day',
      'bg-night',
      'accent-day-custom',
      'accent-night-custom',
      'container-day',
      'container-night',
      'text-day',
      'text-night',
    ]) {
      expect(find.byKey(colorRow(name)), findsOneWidget, reason: name);
    }
    expect(find.byKey(colorRow('accent-day')), findsNothing);

    // 切到种子色：调色板出现，仅 2 行种子色
    await selectDropdown(
      tester,
      const ValueKey('reader-menu-color-mode-dropdown'),
      '种子色',
    );
    expect(
      find.byKey(const ValueKey('reader-menu-palette-dropdown')),
      findsOneWidget,
    );
    expect(find.byKey(colorRow('accent-day')), findsOneWidget);
    expect(find.byKey(colorRow('accent-night')), findsOneWidget);
    expect(find.byKey(colorRow('bg-day')), findsNothing);

    // 取色写入种子色
    await tester.ensureVisible(find.byKey(colorRow('accent-day')));
    await tester.tap(find.byKey(colorRow('accent-day')));
    await tester.pumpAndSettle();
    expect(find.byType(ContainerColorDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'FF123456');
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.readMenuAccentColor), 0xFF123456);

    // 切回自定义主题色，取背景色
    await selectDropdown(
      tester,
      const ValueKey('reader-menu-color-mode-dropdown'),
      '自定义主题色',
    );
    await tester.ensureVisible(find.byKey(colorRow('bg-day')));
    await tester.tap(find.byKey(colorRow('bg-day')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'FF112233');
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.readMenuBgColor), 0xFF112233);
    expect(find.text('#FF112233'), findsOneWidget);
  });

  testWidgets('底栏布局：开关/滑块即时落盘，滑块范围对齐参考版', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.byKey(const ValueKey('reader-menu-tab-1')));
    await tester.pump();

    final itemsSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-menu-items-per-row-slider')),
    );
    expect(itemsSlider.min, 2);
    expect(itemsSlider.max, 8);
    expect(itemsSlider.divisions, 6);
    expect(itemsSlider.value, 5);

    final rowSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-menu-row-count-slider')),
    );
    expect(rowSlider.min, 1);
    expect(rowSlider.max, 2);
    expect(rowSlider.divisions, 1);

    final cornerSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-menu-corner-slider')),
    );
    expect(cornerSlider.min, 0);
    expect(cornerSlider.max, 32);
    expect(cornerSlider.divisions, 32);
    expect(cornerSlider.value, 32);

    await tester.tap(
      find.byKey(const ValueKey('reader-menu-icon-text-switch')),
    );
    await tester.pump();

    itemsSlider.onChanged!(3);
    await tester.pump();
    rowSlider.onChanged!(2);
    await tester.pump();
    cornerSlider.onChanged!(12);
    await tester.pump();

    await tester.ensureVisible(
      find.byKey(const ValueKey('reader-menu-floating-switch')),
    );
    await tester.tap(find.byKey(const ValueKey('reader-menu-floating-switch')));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.readMenuIconShowText), isTrue);
    expect(prefs.getInt(PrefKeys.readMenuIconItemsPerRow), 3);
    expect(prefs.getInt(PrefKeys.readMenuIconRowCount), 2);
    expect(prefs.getInt(PrefKeys.readMenuBottomCornerRadius), 12);
    expect(prefs.getBool(PrefKeys.readMenuFloatingBottomBar), isFalse);
  });

  testWidgets('顶栏布局：胶囊隐藏标题模式行 / 图标样式 / 合并按钮', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.byKey(const ValueKey('reader-menu-tab-2')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('reader-menu-title-mode-dropdown')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('reader-menu-title-capsule-switch')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('reader-menu-title-mode-dropdown')),
      findsNothing,
      reason: '胶囊开启时隐藏标题显示方式（对齐参考版）',
    );

    await selectDropdown(
      tester,
      const ValueKey('reader-menu-title-icon-style-dropdown'),
      '描边',
    );
    await tester.tap(find.byKey(const ValueKey('reader-menu-merge-switch')));
    await tester.pump();

    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.readMenuTopBarTitleCapsule), isTrue);
    expect(prefs.getInt(PrefKeys.titleBarIconStyle), 2);
    expect(prefs.getBool(PrefKeys.readMenuTopBarMergeButtons), isTrue);

    // 关闭胶囊后标题模式行恢复；选择「仅章节」落盘 '2'
    await tester.tap(
      find.byKey(const ValueKey('reader-menu-title-capsule-switch')),
    );
    await tester.pump();
    await selectDropdown(
      tester,
      const ValueKey('reader-menu-title-mode-dropdown'),
      '仅章节',
    );
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.titleBarMode), '2');
  });
}
