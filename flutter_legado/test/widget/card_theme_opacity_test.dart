// [设置批2b-1b-2b | 2026-11-03] 全局默认 Card 卡面不透明度渲染测试 — 全栈工程师 + UI
//
// 参考 GlassCard.kt:74-75：卡面底色 alpha 乘 containerOpacity/100。
// 覆盖：100% 保持主题色；50% alpha=0.5（亮/暗）；0 全透明；显式 color
// 的卡片不受影响（只覆盖使用 CardTheme 默认色的卡片）；透明调色板的 role
// 乘原 alpha 不洗白（纯函数层已单测，此处验证 Material 实际 alpha）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/card_style.dart';

void main() {
  setUp(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  Widget wrap(ThemeData theme) => MaterialApp(
    theme: theme,
    home: const Scaffold(
      body: Column(
        children: [
          Card(child: ListTile(title: Text('默认卡片'))),
          Card(
            color: Color(0xFF3366CC),
            child: ListTile(title: Text('自定义色卡片')),
          ),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(4)),
            ),
            child: ListTile(title: Text('自定义形状卡片')),
          ),
        ],
      ),
    ),
  );

  Color? materialColor(WidgetTester tester, String text) {
    final card = find.ancestor(
      of: find.text(text),
      matching: find.byType(Card),
    );
    final material = find
        .descendant(of: card, matching: find.byType(Material))
        .first;
    return tester.widget<Material>(material).color;
  }

  testWidgets('默认 100%：默认卡片保持主题卡面色，显式色不变', (tester) async {
    await tester.pumpWidget(wrap(AppTheme.light));
    await tester.pumpAndSettle();

    final theme = AppTheme.light;
    expect(materialColor(tester, '默认卡片'), theme.cardTheme.color);
    expect(materialColor(tester, '默认卡片')!.a, closeTo(1.0, 0.001));
    expect(materialColor(tester, '自定义色卡片'), const Color(0xFF3366CC));
    expect(
      materialColor(tester, '自定义形状卡片'),
      theme.cardTheme.color,
      reason: '显式 shape 但未显式 color：color 仍继承 CardTheme',
    );
  });

  testWidgets('containerOpacity 50：默认卡片 alpha=0.5，显式色仍不透明', (tester) async {
    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
    await tester.pumpWidget(wrap(AppTheme.light));
    await tester.pumpAndSettle();

    expect(materialColor(tester, '默认卡片')!.a, closeTo(0.5, 0.001));
    expect(
      materialColor(tester, '自定义色卡片')!.a,
      closeTo(1.0, 0.001),
      reason: '显式 color 的卡片不在 CardTheme 覆盖内',
    );
    expect(
      materialColor(tester, '自定义形状卡片')!.a,
      closeTo(0.5, 0.001),
      reason: '显式 shape 未显式 color 的卡片同样乘 alpha',
    );

    // 暗色卡面 role（surfaceContainerLow）同样乘 alpha
    await tester.pumpWidget(wrap(AppTheme.dark));
    await tester.pumpAndSettle();
    expect(materialColor(tester, '默认卡片')!.a, closeTo(0.5, 0.001));
  });

  testWidgets('containerOpacity 0：默认卡片全透明', (tester) async {
    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 0);
    await tester.pumpWidget(wrap(AppTheme.light));
    await tester.pumpAndSettle();
    expect(materialColor(tester, '默认卡片')!.a, 0.0);
  });

  testWidgets('透明调色板：50% 乘原 alpha（0.2→0.1）不洗白', (tester) async {
    // 构造与 AppTheme 同口径的 ThemeData：卡面 role 自带 0x33 alpha，
    // 验证 Material 实际绘制 alpha 为 0.2 × 0.5（而非被覆盖成 0.5/1.0）。
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.blue,
    ).copyWith(surfaceContainerLowest: const Color(0x33FFFFFF));
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      cardTheme: CardThemeData(
        color: resolveCardThemeColor(scheme.surfaceContainerLowest, 50),
      ),
    );
    await tester.pumpWidget(wrap(theme));
    await tester.pumpAndSettle();
    expect(materialColor(tester, '默认卡片')!.a, closeTo(0.1, 0.001));
  });
}
