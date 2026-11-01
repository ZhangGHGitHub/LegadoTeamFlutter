// [设置批2b-1b-1 | 2026-11-01] IosGroup 卡片圆角/边框/分隔线渲染测试 — 全栈工程师
//
// 覆盖：默认 16dp 无边框无分隔线（旧行为）；圆角覆盖；disable 分组圆角
// 优先级；边框日/夜色与 0 色回落 outlineVariant；边框不改变布局尺寸；
// 分隔线插入位置/条数/宽度/长度百分比/颜色/宽度 0；AppTheme 全局
// CardTheme 同步圆角与边框。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/pill_divider.dart';

void main() {
  setUp(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  Widget wrap({Brightness brightness = Brightness.light, int rows = 2}) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: brightness,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: IosGroup(
              children: [
                for (var i = 0; i < rows; i++) IosListTile(title: '行$i'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget wrapFlat({Brightness brightness = Brightness.light, int rows = 2}) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: brightness,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: IosGroup(
              flat: true,
              children: [
                for (var i = 0; i < rows; i++) IosListTile(title: '行$i'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Finder clip() => find
      .descendant(of: find.byType(IosGroup), matching: find.byType(ClipRRect))
      .first;

  Finder frame() => find.byKey(const ValueKey('ios-group-frame'));

  Container frameWidget(WidgetTester tester) =>
      tester.widget<Container>(frame());

  BoxDecoration? frameForeground(WidgetTester tester) {
    final decoration = frameWidget(tester).foregroundDecoration;
    return decoration is BoxDecoration ? decoration : null;
  }

  int gapCount(WidgetTester tester) => tester
      .widgetList<SizedBox>(
        find.descendant(
          of: find.byType(IosGroup),
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.height == 2,
          ),
        ),
      )
      .length;

  group('默认旧行为', () {
    testWidgets('圆角 16dp、无边框、无分隔线、每对行一个 2dp 间距', (tester) async {
      await tester.pumpWidget(wrap(rows: 2));
      await tester.pumpAndSettle();

      final clipWidget = tester.widget<ClipRRect>(clip());
      expect(clipWidget.borderRadius, BorderRadius.circular(16));

      final surface = tester.widget<Container>(
        find.byKey(const ValueKey('ios-group-surface')),
      );
      expect(
        (surface.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(16),
      );
      expect(frameForeground(tester), isNull);
      expect(find.byType(PillDivider), findsNothing);
      expect(gapCount(tester), 1);
    });

    testWidgets('单行分组：开关开也不产生分隔线（末行不留线）', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 1,
      );
      await tester.pumpWidget(wrap(rows: 1));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsNothing);
    });
  });

  group('卡片圆角覆盖', () {
    testWidgets('override=true 取 baseCardCornerRadius；0=直角', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardCornerRadius: true,
        baseCardCornerRadius: 24,
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(
        tester.widget<ClipRRect>(clip()).borderRadius,
        BorderRadius.circular(24),
      );

      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardCornerRadius: true,
        baseCardCornerRadius: 0,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<ClipRRect>(clip()).borderRadius, BorderRadius.zero);
    });

    testWidgets('disableSplicedColumnGroupCornerRadius 优先于圆角覆盖', (
      tester,
    ) async {
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardCornerRadius: true,
        baseCardCornerRadius: 28,
        disableSplicedColumnGroupCornerRadius: true,
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(tester.widget<ClipRRect>(clip()).borderRadius, BorderRadius.zero);
      expect(
        (tester
                    .widget<Container>(
                      find.byKey(const ValueKey('ios-group-surface')),
                    )
                    .decoration!
                as BoxDecoration)
            .borderRadius,
        BorderRadius.zero,
      );
    });

    testWidgets('圆角 0 时内容仍完整渲染', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardCornerRadius: true,
        baseCardCornerRadius: 0,
      );
      await tester.pumpWidget(wrap(rows: 2));
      await tester.pumpAndSettle();
      expect(find.text('行0'), findsOneWidget);
      expect(find.text('行1'), findsOneWidget);
    });
  });

  group('卡片边框覆盖', () {
    testWidgets('日间：按宽度与日间色绘制，不改变分组尺寸', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      final sizeBefore = tester.getSize(find.byType(IosGroup));

      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 2,
        baseCardBorderColor: 0xFF112233,
        baseCardBorderColorNight: 0xFF445566,
      );
      await tester.pumpAndSettle();

      final decoration = frameForeground(tester)!;
      final border = decoration.border! as Border;
      expect(border.top.width, 2);
      expect(border.top.color, const Color(0xFF112233));
      expect(border.bottom.color, const Color(0xFF112233));
      expect(
        tester.getSize(find.byType(IosGroup)),
        sizeBefore,
        reason: '边框用 foregroundDecoration 绘制，不得改变布局尺寸',
      );
    });

    testWidgets('夜间：取夜间色；0 色回落 outlineVariant', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 1,
        baseCardBorderColor: 0xFF112233,
        baseCardBorderColorNight: 0xFF445566,
      );
      await tester.pumpWidget(wrap(brightness: Brightness.dark));
      await tester.pumpAndSettle();

      var border = frameForeground(tester)!.border! as Border;
      expect(border.top.color, const Color(0xFF445566));

      final scheme = Theme.of(
        tester.element(find.byType(IosGroup)),
      ).colorScheme;
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 1,
        baseCardBorderColor: 0xFF112233,
        baseCardBorderColorNight: 0,
      );
      await tester.pumpAndSettle();
      border = frameForeground(tester)!.border! as Border;
      expect(border.top.color, scheme.outlineVariant);

      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 1,
        baseCardBorderColor: 0,
        baseCardBorderColorNight: 0xFF445566,
      );
      await tester.pumpWidget(wrap(brightness: Brightness.light));
      await tester.pumpAndSettle();
      final lightScheme = Theme.of(
        tester.element(find.byType(IosGroup)),
      ).colorScheme;
      border = frameForeground(tester)!.border! as Border;
      expect(border.top.color, lightScheme.outlineVariant);
    });

    testWidgets('开关关 / 宽度 0：无边框装饰', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 1,
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(frameForeground(tester), isNotNull);

      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: false,
        baseCardBorderWidth: 1,
      );
      await tester.pumpAndSettle();
      expect(frameForeground(tester), isNull);

      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 0,
      );
      await tester.pumpAndSettle();
      expect(frameForeground(tester), isNull);
    });
  });

  group('条目分隔线', () {
    testWidgets('开启：相邻行之间插入一条；2dp 间距保留', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 1,
        itemDividerLength: 80,
      );
      await tester.pumpWidget(wrap(rows: 2));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-group-divider-0')), findsOneWidget);
      // 行0 + 2dp + 线 + 2dp + 行1（参考版 Column spacedBy(2) 同构）
      expect(gapCount(tester), 2);

      final line = tester.widget<Container>(
        find.descendant(
          of: find.byType(PillDivider),
          matching: find.byType(Container),
        ),
      );
      final lineSize = tester.getSize(
        find
            .descendant(
              of: find.byType(PillDivider),
              matching: find.byType(Container),
            )
            .first,
      );
      // 分组外宽 400；80% = 320（分隔线按外宽计算，不含 4dp 行内缩进）
      expect(lineSize.width, closeTo(400 * 0.8, 0.01));
      expect(lineSize.height, 1);
      final color = (line.decoration! as BoxDecoration).color!;
      expect(color.a, closeTo(0.3, 0.001), reason: '0 色回落灰色 30%');
    });

    testWidgets('三行 → 两条分隔线，键按序号区分', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 2,
        itemDividerLength: 50,
      );
      await tester.pumpWidget(wrap(rows: 3));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsNWidgets(2));
      expect(find.byKey(const ValueKey('ios-group-divider-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-group-divider-1')), findsOneWidget);
      expect(gapCount(tester), 4);

      final lineSize = tester.getSize(
        find
            .descendant(
              of: find.byType(PillDivider),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(lineSize.width, closeTo(400 * 0.5, 0.01));
      expect(lineSize.height, 2);
    });

    testWidgets('显式颜色原样使用', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 1,
        itemDividerColor: 0xFFFF0000,
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      final line = tester.widget<Container>(
        find.descendant(
          of: find.byType(PillDivider),
          matching: find.byType(Container),
        ),
      );
      expect(
        (line.decoration! as BoxDecoration).color,
        const Color(0xFFFF0000),
      );
    });

    testWidgets('宽度 0：不绘制线，行间仍按参考版保留间距', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 0,
      );
      await tester.pumpWidget(wrap(rows: 2));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PillDivider),
          matching: find.byType(Container),
        ),
        findsNothing,
      );
      expect(gapCount(tester), 2);
    });

    testWidgets('关闭：无线、仅 2dp 间距（旧行为）', (tester) async {
      await tester.pumpWidget(wrap(rows: 3));
      await tester.pumpAndSettle();
      expect(find.byType(PillDivider), findsNothing);
      expect(gapCount(tester), 2);
    });
  });

  group('扁平分组分隔线', () {
    testWidgets('开关开：使用 PillDivider 参数（外宽 80%、宽 2、0 色灰 30%）',
        (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 2,
        itemDividerLength: 80,
      );
      await tester.pumpWidget(wrapFlat(rows: 2));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ios-group-flat-divider-0')),
        findsOneWidget,
      );
      // flat 无卡片面：不再出现卡片分组专用结构/旧细线
      expect(find.byType(Divider), findsNothing);

      final lineFinder = find.descendant(
        of: find.byType(PillDivider),
        matching: find.byType(Container),
      );
      final size = tester.getSize(lineFinder);
      expect(size.width, closeTo(400 * 0.8, 0.01));
      expect(size.height, 2);
      final color =
          (tester.widget<Container>(lineFinder).decoration! as BoxDecoration)
              .color!;
      expect(color.a, closeTo(0.3, 0.001));
    });

    testWidgets('开关开：长度 50% 与显式颜色生效', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 1,
        itemDividerLength: 50,
        itemDividerColor: 0xFFFF0000,
      );
      await tester.pumpWidget(wrapFlat(rows: 3));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsNWidgets(2));
      final lineFinder = find
          .descendant(
            of: find.byType(PillDivider),
            matching: find.byType(Container),
          )
          .first;
      expect(tester.getSize(lineFinder).width, closeTo(400 * 0.5, 0.01));
      expect(
        (tester.widget<Container>(lineFinder).decoration! as BoxDecoration)
            .color,
        const Color(0xFFFF0000),
      );
    });

    testWidgets('开关关：保留既有 0.5dp 细线（旧形态）', (tester) async {
      await tester.pumpWidget(wrapFlat(rows: 3));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsNothing);
      final dividers = tester.widgetList<Divider>(find.byType(Divider));
      expect(dividers.length, 2);
      expect(dividers.first.thickness, 0.5);
      final theme = Theme.of(tester.element(find.byType(IosGroup)));
      expect(dividers.first.color, theme.dividerColor);
    });

    testWidgets('宽度 0：开关开也不绘制线', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 0,
      );
      await tester.pumpWidget(wrapFlat(rows: 2));
      await tester.pumpAndSettle();

      expect(find.byType(PillDivider), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PillDivider),
          matching: find.byType(Container),
        ),
        findsNothing,
      );
    });
  });

  group('全局 CardTheme（可复用卡片 surface）', () {
    test('默认 20dp 无边框；覆盖后圆角/边框同步', () {
      final defaultShape =
          AppTheme.light.cardTheme.shape! as RoundedRectangleBorder;
      expect(defaultShape.borderRadius, BorderRadius.circular(20));
      expect(defaultShape.side, BorderSide.none);

      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardCornerRadius: true,
        baseCardCornerRadius: 9,
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 2,
        baseCardBorderColor: 0xFF102030,
        baseCardBorderColorNight: 0xFF405060,
      );
      final lightShape =
          AppTheme.light.cardTheme.shape! as RoundedRectangleBorder;
      expect(lightShape.borderRadius, BorderRadius.circular(9));
      expect(lightShape.side.width, 2);
      expect(lightShape.side.color, const Color(0xFF102030));

      final darkShape =
          AppTheme.dark.cardTheme.shape! as RoundedRectangleBorder;
      expect(darkShape.borderRadius, BorderRadius.circular(9));
      expect(darkShape.side.color, const Color(0xFF405060));

      // 0 色回落 outlineVariant
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 1,
      );
      final fallbackShape =
          AppTheme.light.cardTheme.shape! as RoundedRectangleBorder;
      expect(
        fallbackShape.side.color,
        AppTheme.light.colorScheme.outlineVariant,
      );

      // disable 分组圆角不影响全局卡片档
      uiSettingsListenable.value = const UiSettingsState(
        disableSplicedColumnGroupCornerRadius: true,
      );
      final disabledShape =
          AppTheme.light.cardTheme.shape! as RoundedRectangleBorder;
      expect(disabledShape.borderRadius, BorderRadius.circular(20));
    });

    testWidgets('默认样式 Card 出边框；显式 shape Card 不随覆盖', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        overrideBaseCardCornerRadius: true,
        baseCardCornerRadius: 9,
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 2,
        baseCardBorderColor: 0xFF102030,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Column(
              children: [
                Card(child: ListTile(title: Text('默认卡片'))),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: ListTile(title: Text('自定义卡片')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      ShapeBorder? materialShape(String text) {
        final card = find.ancestor(
          of: find.text(text),
          matching: find.byType(Card),
        );
        final material = find
            .descendant(of: card, matching: find.byType(Material))
            .first;
        return tester.widget<Material>(material).shape;
      }

      // 范围锁定：默认样式随 CardTheme 覆盖
      final defaultShape =
          materialShape('默认卡片')! as RoundedRectangleBorder;
      expect(defaultShape.borderRadius, BorderRadius.circular(9));
      expect(defaultShape.side.width, 2);
      expect(defaultShape.side.color, const Color(0xFF102030));

      // 显式 shape（18 处之一）保持自身，不随全局覆盖
      final customShape =
          materialShape('自定义卡片')! as RoundedRectangleBorder;
      expect(customShape.borderRadius, BorderRadius.circular(4));
      expect(customShape.side, BorderSide.none);
    });
  });
}
