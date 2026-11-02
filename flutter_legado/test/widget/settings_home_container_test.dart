// [设置批2b-1b-2a | 2026-11-02] 设置首页手写卡片容器不透明度测试 — 全栈工程师
//
// 设置首页入口卡为手写 Material（16dp 圆角、10dp 行距），不经过 IosGroup/
// CardTheme；本文件验证其卡面 alpha 按 containerOpacity 乘 alpha（文字不受
// 影响），并保持 8 个入口结构不变。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';

void main() {
  setUp(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  Widget wrap({ColorScheme? scheme}) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: scheme ?? ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const SettingsHomeScreen(),
    );
  }

  Future<void> pumpPage(WidgetTester tester, {ColorScheme? scheme}) async {
    // 放得下 8 个入口（SliverList 懒构建，小视口会少建）
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(scheme: scheme));
    await tester.pumpAndSettle();
  }

  List<Material> cardMaterials(WidgetTester tester) => tester
      .widgetList<Material>(
        find.descendant(
          of: find.byType(SettingsHomeScreen),
          matching: find.byType(Material),
        ),
      )
      .where((m) => m.borderRadius == BorderRadius.circular(16))
      .toList();

  testWidgets('默认 100%：卡面保持主题 surfaceContainerLow alpha，8 个入口', (tester) async {
    await pumpPage(tester);

    expect(cardMaterials(tester).length, 8);
    final scheme = Theme.of(
      tester.element(find.byType(SettingsHomeScreen)),
    ).colorScheme;
    final materials = cardMaterials(tester);
    expect(materials.length, 8);
    for (final material in materials) {
      expect(
        material.color!.a,
        closeTo(scheme.surfaceContainerLow.a, 0.001),
        reason: '100% 时不得改变主题卡面 alpha',
      );
    }
    // 手写结构保留：8 个入口之间 7 条 10dp 分隔
    expect(
      find.byWidgetPredicate(
        (w) => w is SizedBox && w.height == 10,
        skipOffstage: false,
      ),
      findsNWidgets(7),
    );
  });

  testWidgets('容器不透明度 50%：8 张手写卡片 alpha=0.5，文字仍不透明', (tester) async {
    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
    await pumpPage(tester);

    final items = cardMaterials(tester);
    expect(items.length, 8);
    for (final material in items) {
      expect(material.color!.a, closeTo(0.5, 0.001));
    }

    // [P2-1] 文字不得被任何 Opacity/RenderOpacity 包裹而整体变淡：
    // 只允许 Material.color 半透明，文字节点自身保持不透明。
    expect(
      find.ancestor(
        of: find.text('外观'),
        matching: find.byType(Opacity),
      ),
      findsNothing,
      reason: '卡面半透明不得通过 Opacity 祖先降低文字透明度',
    );
  });

  testWidgets('透明调色板：50% 乘底 alpha（0.2→0.1），100% 保持 0.2', (tester) async {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.blue,
    ).copyWith(surfaceContainerLow: const Color(0x33FFFFFF));

    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 100);
    await pumpPage(tester, scheme: scheme);
    expect(cardMaterials(tester).first.color!.a, closeTo(0.2, 0.001));

    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
    await tester.pumpAndSettle();
    expect(cardMaterials(tester).first.color!.a, closeTo(0.1, 0.001));
  });

  testWidgets('容器不透明度变化即时重建（ValueListenable 通道）', (tester) async {
    await pumpPage(tester);
    expect(cardMaterials(tester).first.color!.a, closeTo(1.0, 0.001));

    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 0);
    await tester.pumpAndSettle();
    expect(cardMaterials(tester).first.color!.a, closeTo(0.0, 0.001));
  });
}
