// [M3 我的页 | full-stack-engineer + UI | 2026-11-03]
// IosGroup 分组 footer 能力 widget 测试
//
// 参考版 `WebServiceSettingBlock`：运行中操作按钮 Row 位于
// `SplicedColumnGroup` 分组 Column 内、且不是卡片行（无行卡、无分隔线）。
// 覆盖：
// 1. footer 渲染在分组容器内（surface / 背景图之上、圆角裁剪内）；
// 2. footer 不套行卡（不生成 surfaceContainerLow Material）；
// 3. footer 不参与行分隔线与 2dp 行距；
// 4. 容器背景图 + 自定义边框一并包裹 footer（不越出裁剪区）；
// 5. flat 模式同样渲染 footer；默认 footer=null 不占位（既有调用不破坏）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/pill_divider.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

void main() {
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legado_ios_group_footer_');
    originalSupportDir = ThemeBackgroundImageStore.supportDir;
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() async {
    uiSettingsListenable.value = const UiSettingsState();
    ThemeBackgroundImageStore.supportDir = originalSupportDir;
    ThemeBackgroundImageStore.resetWarmCache();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<String> storePng(String slot) async {
    final source = File('${temp.path}${Platform.pathSeparator}$slot-src.png');
    await source.writeAsBytes(_pngBytes);
    return ThemeBackgroundImageStore.store(source.path, slot: slot);
  }

  const footerKey = ValueKey('test-group-footer');

  Widget footerBody() => const Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          key: footerKey,
          width: double.infinity,
          height: 40,
          child: Text('分组脚注'),
        ),
      );

  Widget wrap({
    bool flat = false,
    bool withFooter = true,
    int rows = 2,
    Brightness brightness = Brightness.light,
  }) {
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
              flat: flat,
              footer: withFooter ? footerBody() : null,
              children: [
                for (var i = 0; i < rows; i++) IosListTile(title: '行$i'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Finder footer() => find.byKey(footerKey);

  Finder groupFooterWrapper() => find.byKey(const ValueKey('ios-group-footer'));

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

  group('卡片分组 footer', () {
    testWidgets('footer 在分组容器 surface 内、最后一行下方，且不套行卡', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final group = find.byType(IosGroup);
      final surface = find.byKey(const ValueKey('ios-group-surface'));
      expect(footer(), findsOneWidget);
      expect(groupFooterWrapper(), findsOneWidget);
      expect(
        find.descendant(of: surface, matching: footer()),
        findsOneWidget,
        reason: 'footer 必须在分组容器 surface 内（参考版 SplicedColumnGroup 内）',
      );

      final scheme = Theme.of(tester.element(group)).colorScheme;
      final rowCards = tester
          .widgetList<Material>(
            find.descendant(of: group, matching: find.byType(Material)),
          )
          .where((m) => m.color == scheme.surfaceContainerLow)
          .toList();
      expect(rowCards.length, 2, reason: '仅两行各有一张行卡');
      expect(
        find.ancestor(
          of: footer(),
          matching: find.byWidgetPredicate(
            (w) => w is Material && w.color == scheme.surfaceContainerLow,
          ),
        ),
        findsNothing,
        reason: 'footer 不套行卡（不生成 surfaceContainerLow Material）',
      );

      // 位置：最后一行（行卡，非行内文本）之下；水平内边距 16dp
      //（与行内容/参考版对齐）
      final lastRow = find.byType(IosListTile).last;
      final footerRect = tester.getRect(footer());
      expect(
        footerRect.top,
        greaterThan(tester.getRect(lastRow).bottom),
        reason: 'footer 位于最后一行下方',
      );
      final groupRect = tester.getRect(group);
      expect(footerRect.left, closeTo(groupRect.left + 16, 0.5));
      expect(footerRect.right, closeTo(groupRect.right - 16, 0.5));
      expect(
        footerRect.top - tester.getRect(lastRow).bottom,
        inInclusiveRange(8, 12),
        reason: 'footer 垂直内边距 12dp（任务要求 8~12dp）',
      );
    });

    testWidgets('footer 不参与行分隔线与 2dp 行距', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 1,
        itemDividerLength: 80,
      );
      await tester.pumpWidget(wrap(rows: 3));
      await tester.pumpAndSettle();

      // 3 行 → 2 条分隔线（仅相邻行之间）；footer 前不多画一条
      expect(find.byType(PillDivider), findsNWidgets(2));
      expect(find.byKey(const ValueKey('ios-group-divider-2')), findsNothing,
          reason: 'footer 不是行，不生成第 3 条分隔线');
      expect(gapCount(tester), 4, reason: '仅行间 2dp × 4（每线两侧）');
    });

    testWidgets('容器背景图与边框包裹 footer（不越出裁剪区）', (tester) async {
      final light = (await tester.runAsync(() => storePng('large_light')))!;
      uiSettingsListenable.value = UiSettingsState(
        enableContainerBackgroundImage: true,
        largeContainerBackgroundImageLight: light,
        overrideBaseCardBorder: true,
        baseCardBorderWidth: 2,
      );
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(milliseconds: 300));

      final image = find.byKey(const ValueKey('ios-group-container-background'));
      expect(image, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ios-group-frame')),
          matching: find.byType(ClipRRect),
        ),
        findsWidgets,
        reason: '圆角裁剪包裹整个容器（含 footer）',
      );
      final clip = find.ancestor(
        of: footer(),
        matching: find.byType(ClipRRect),
      );
      expect(clip, findsWidgets, reason: 'footer 处于分组圆角裁剪子树内');

      final imageRect = tester.getRect(image);
      final footerRect = tester.getRect(footer());
      expect(footerRect.left, greaterThanOrEqualTo(imageRect.left));
      expect(footerRect.right, lessThanOrEqualTo(imageRect.right));
      expect(footerRect.bottom, lessThanOrEqualTo(imageRect.bottom),
          reason: 'footer 不越出容器背景图区域');
      expect(
        tester
            .widget<Container>(find.byKey(const ValueKey('ios-group-frame')))
            .foregroundDecoration,
        isA<BoxDecoration>(),
        reason: '自定义边框仍绘制在整个容器（含 footer）之上',
      );
    });

    testWidgets('containerOpacity 只作用于行卡，不影响 footer 卡片面', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final scheme = Theme.of(tester.element(find.byType(IosGroup))).colorScheme;
      final rowCard = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byType(IosGroup),
              matching: find.byType(Material),
            ),
          )
          .firstWhere((m) => m.color == scheme.surfaceContainerLow.withValues(
                alpha: scheme.surfaceContainerLow.a * 0.5,
              ));
      expect(rowCard.color!.a, closeTo(0.5, 0.001));
      expect(
        find.ancestor(
          of: footer(),
          matching: find.byWidgetPredicate(
            (w) => w is Material && w.color == scheme.surfaceContainerLow,
          ),
        ),
        findsNothing,
        reason: 'footer 无卡片面，containerOpacity 不适用',
      );
    });
  });

  group('flat 模式 / 默认兼容', () {
    testWidgets('flat 模式同样在末尾渲染 footer（不插分隔线）', (tester) async {
      uiSettingsListenable.value = const UiSettingsState(
        enableItemDivider: true,
        itemDividerWidth: 1,
      );
      await tester.pumpWidget(wrap(flat: true, rows: 2));
      await tester.pumpAndSettle();

      expect(footer(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ios-group-footer')),
          matching: footer(),
        ),
        findsOneWidget,
      );
      // 2 行 → 1 条扁平分隔线；footer 不额外产生分隔线
      expect(find.byType(PillDivider), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ios-group-flat-divider-1')),
        findsNothing,
      );
    });

    testWidgets('footer=null（默认）：不占位、不影响既有布局', (tester) async {
      await tester.pumpWidget(wrap(withFooter: false));
      await tester.pumpAndSettle();

      expect(groupFooterWrapper(), findsNothing);
      expect(find.text('行0'), findsOneWidget);
      expect(find.text('行1'), findsOneWidget);
      expect(gapCount(tester), 1);
    });
  });
}
