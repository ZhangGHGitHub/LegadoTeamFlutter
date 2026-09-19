// [深色主题 Batch A-1] 漫画设置底栏 scheme 化回归测试
//
// 背景：MangaConfigSheet 原硬编码 iOS 浅色调色板（#F2F2F7 底 / 白卡 /
// #1C1C1E 主文字 / #8E8E93 次文字 / #E5E5EA 分隔线 / #C7C7CC 把手），
// 暗色主题下无法跟随。Batch A-1 全部改为 Theme scheme 槽位，本测试：
// 1. 暗色主题下无异常渲染，且各颜色取自 dark scheme（旧硬编码色不再出现）；
// 2. 亮色主题下颜色取自 light scheme（亮色外观由 scheme 值锚定，防回归）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/manga_config.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/widgets/manga/manga_config_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildSheet(ThemeMode mode) {
    return MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      home: Scaffold(
        body: MangaConfigSheet(
          // MangaColorFilterConfig 字段可变态，构造器非 const
          colorFilter: MangaColorFilterConfig(r: 12, l: 40),
          footer: MangaFooterConfig(),
          enableEInk: false,
          enableGray: false,
          eInkThreshold: 128,
          onColorFilterChanged: (_) {},
          onFooterChanged: (_) {},
          onEnableEInkChanged: (_) {},
          onEnableGrayChanged: (_) {},
          onEInkThresholdChanged: (_) {},
        ),
      ),
    );
  }

  /// 收集 sheet 内所有带显式 BoxDecoration.color 的容器颜色集合
  Set<Color> containerColors(WidgetTester tester) {
    final containers = tester.widgetList<Container>(
      find.descendant(of: find.byType(MangaConfigSheet), matching: find.byType(Container)),
    );
    return containers
        .map((c) => (c.decoration as BoxDecoration?)?.color)
        .whereType<Color>()
        .toSet();
  }

  void assertColorsFromScheme(WidgetTester tester, ColorScheme scheme) {
    // 标题 / 滑杆标题 → onSurface
    expect(tester.widget<Text>(find.text('漫画设置')).style!.color, scheme.onSurface);
    expect(tester.widget<Text>(find.text('亮度')).style!.color, scheme.onSurface);

    // 分组标题 / 开关副标题 / 滑杆数值 → onSurfaceVariant
    expect(tester.widget<Text>(find.text('显示效果')).style!.color, scheme.onSurfaceVariant);
    expect(
      tester.widget<Text>(find.text('灰度近似；阈值已持久化')).style!.color,
      scheme.onSurfaceVariant,
    );
    expect(tester.widget<Text>(find.text('40')).style!.color, scheme.onSurfaceVariant);

    // 容器底色：根背景 = surfaceContainerHighest / 卡片 = surface
    final colors = containerColors(tester);
    expect(colors, contains(scheme.surfaceContainerHighest),
        reason: 'sheet 根背景应取自 surfaceContainerHighest');
    expect(colors, contains(scheme.surface),
        reason: '卡片底色应取自 surface');

    // 旧 iOS 硬编码浅色调色板不应再出现
    expect(colors, isNot(contains(const Color(0xFFF2F2F7))),
        reason: '旧硬编码背景 #F2F2F7 不应残留');
    expect(colors, isNot(contains(Colors.white)),
        reason: '旧硬编码白卡不应残留');
    expect(colors, isNot(contains(const Color(0xFFC7C7CC))),
        reason: '旧硬编码把手 #C7C7CC 不应残留');

    // 把手（36×5）→ outlineVariant
    final containers = tester.widgetList<Container>(
      find.descendant(of: find.byType(MangaConfigSheet), matching: find.byType(Container)),
    );
    final handleConstraints = BoxConstraints.tight(const Size(36, 5));
    final handle = containers.singleWhere((c) => c.constraints == handleConstraints);
    expect((handle.decoration as BoxDecoration).color, scheme.outlineVariant,
        reason: '拖动把手应取自 outlineVariant');

    // 分隔线 → outlineVariant
    for (final d in tester.widgetList<Divider>(find.byType(Divider))) {
      expect(d.color, scheme.outlineVariant, reason: '分隔线应取自 outlineVariant');
    }
  }

  testWidgets('暗色主题：无异常渲染且颜色取自 dark scheme', (tester) async {
    await tester.pumpWidget(buildSheet(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    assertColorsFromScheme(tester, AppTheme.dark.colorScheme);
  });

  testWidgets('亮色主题：无异常渲染且颜色取自 light scheme（亮色回归锚定）',
      (tester) async {
    await tester.pumpWidget(buildSheet(ThemeMode.light));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    assertColorsFromScheme(tester, AppTheme.light.colorScheme);
  });
}
