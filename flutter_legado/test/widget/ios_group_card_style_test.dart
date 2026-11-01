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

    testWidgets('开关全关时 IosListTile 不再自绘行底线', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 1,
      );
      await tester.pumpWidget(wrap(rows: 1));
      await tester.pumpAndSettle();

      // 单行分组：项间无分隔线（末行不再多一条）
      expect(find.byType(PillDivider), findsNothing);
      expect(find.byType(ListTile), findsOneWidget);
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
      // 分组宽 400 - 4dp×2 内边距 = 392；80% = 313.6
      expect(lineSize.width, closeTo(392 * 0.8, 0.01));
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
      expect(lineSize.width, closeTo(392 * 0.5, 0.01));
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
  });
}
