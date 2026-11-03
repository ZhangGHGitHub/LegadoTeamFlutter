// [设置批2b-1a | 2026-11-01；2b-1b-2a 层序修正 2026-11-02]
// IosGroup 容器背景图/不透明度 widget 测试 — 全栈工程师
//
// 参考层序（SplicedColumnGroup.kt:107-133）：图片铺满分组最底层，**无整卡
// scrim、无 4dp 行内缩/整卡内边距**；行卡满宽直接叠在图上，仅 2dp 行距与
// 分组圆角边缘露出原图；containerOpacity 只乘行卡 alpha，
// appColumnBackgroundOpacity 只乘图片 alpha。
// 覆盖：默认无图；行卡不透明度；100% 仅 2dp 行距可见图；图片 100/50/0 可见
// 差异；日/夜各取对应背景图；文件缺失回落；背景图不拦截点击。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

/// 行卡 Material（color 非空）；排除项目图内容层的透明 Material
final Finder _rowCardFinder = find.byWidgetPredicate(
  (w) => w is Material && w.color != null,
);

void main() {
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legado_ios_group_');
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

  Widget wrap({
    Brightness brightness = Brightness.light,
    required VoidCallback? onTap,
    int rows = 1,
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
          child: IosGroup(
            children: [
              for (var i = 0; i < rows; i++)
                IosListTile(
                  title: rows == 1 ? '测试行' : '测试行$i',
                  onTap: onTap,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Finder groupSurface() => find.descendant(
        of: find.byType(IosGroup),
        matching: find.byKey(const ValueKey('ios-group-surface')),
      );

  Finder groupStack() => find
      .descendant(of: find.byType(IosGroup), matching: find.byType(Stack))
      .first;

  testWidgets('容器图层序：图片铺满最底层、无整卡 scrim（100% 仅 2dp 行距可见图）',
      (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null, rows: 2));
    await tester.pump(const Duration(milliseconds: 300));

    final stack = tester.widget<Stack>(groupStack());
    expect(stack.children.length, 2);
    expect(stack.children.first, isA<Positioned>(),
        reason: '背景图必须是 Stack 第 0 层（行卡之下）');
    expect(stack.children.last, isA<Container>(),
        reason: '行容器必须在背景图之上');

    // 同一 16dp 圆角裁剪
    final clip = tester.widget<ClipRRect>(
      find.ancestor(of: groupStack(), matching: find.byType(ClipRRect)).first,
    );
    expect(clip.borderRadius, BorderRadius.circular(16));

    // 参考 SplicedColumnGroup：没有整卡 scrim；图片铺满分组，行卡 4dp 内缩/
    // 2dp 行距直接露出原图。100% 只表示行卡不透明，不是图片被完全遮挡。
    final imageFinder =
        find.byKey(const ValueKey('ios-group-container-background'));
    expect(imageFinder, findsOneWidget);
    final surface = tester.widget<Container>(groupSurface());
    expect((surface.decoration as BoxDecoration).color, isNull,
        reason: '不得存在整卡 groupSurface scrim');
    expect(surface.padding, isNull, reason: '整卡无 4dp 内边距');
    expect(
      tester.getSize(groupSurface()),
      tester.getSize(imageFinder),
      reason: '行容器与背景图同尺寸，图片从 2dp 行距/圆角露出',
    );
    expect(
      tester.getSize(groupSurface()),
      tester.getSize(find.byType(IosGroup)),
      reason: '图片铺满分组卡（行卡满宽，无 4dp 边距）',
    );
    // 2 行 → 1 个 2dp 行距（100% 时唯一的图片露出通道，无 4dp 彩色边框）
    expect(
      find.descendant(
        of: find.byType(IosGroup),
        matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.height == 2,
        ),
      ),
      findsOneWidget,
    );
    final rowFinder = find.descendant(
      of: find.byType(IosGroup),
      matching: _rowCardFinder,
    );
    final rows = tester.widgetList<Material>(rowFinder);
    expect(rows.length, 2);
    final groupWidth = tester.getSize(find.byType(IosGroup)).width;
    for (final row in rows) {
      expect(row.color!.a, closeTo(1.0, 0.001),
          reason: '默认 containerOpacity=100 → 行卡不透明');
    }
    for (var i = 0; i < rows.length; i++) {
      expect(
        tester.getSize(rowFinder.at(i)).width,
        groupWidth,
        reason: '行卡满宽（不得保留 4dp 水平内缩）',
      );
    }
    expect(
      tester
          .widget<Opacity>(
            find.byKey(
              const ValueKey('ios-group-container-background-opacity'),
            ),
          )
          .opacity,
      closeTo(1.0, 0.001),
    );
  });

  testWidgets('containerOpacity 50：仅行卡 alpha=0.5，整卡无 scrim', (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      containerOpacity: 50,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final surface = tester.widget<Container>(groupSurface());
    expect((surface.decoration as BoxDecoration).color, isNull);
    expect(surface.padding, isNull);
    final rowFinder = find.descendant(
      of: find.byType(IosGroup),
      matching: _rowCardFinder,
    );
    final row = tester.widget<Material>(rowFinder);
    expect(row.color!.a, closeTo(0.5, 0.001));
    expect(
      tester.getSize(rowFinder).width,
      tester.getSize(find.byType(IosGroup)).width,
      reason: '行卡满宽，50% 时整行卡面透出、无 4dp 边框',
    );
    // 图片只受 appColumnBackgroundOpacity（默认 100）控制，缝隙保持全强度
    expect(
      tester
          .widget<Opacity>(
            find.byKey(
              const ValueKey('ios-group-container-background-opacity'),
            ),
          )
          .opacity,
      closeTo(1.0, 0.001),
    );
    expect(
      tester.getSize(groupSurface()),
      tester.getSize(
        find.byKey(const ValueKey('ios-group-container-background')),
      ),
    );
  });

  testWidgets('图片透明度在默认 100% 行卡下可见：100→1、50→0.5、0→透明',
      (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    final imageOpacity = find.byKey(
      const ValueKey('ios-group-container-background-opacity'),
    );
    final rowFinder = find.descendant(
      of: find.byType(IosGroup),
      matching: _rowCardFinder,
    );
    final surfaceFinder = groupSurface();

    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null, rows: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Opacity>(imageOpacity).opacity, closeTo(1.0, 0.001),
        reason: '默认 appColumnBackgroundOpacity=100 → 图片不透明');
    expect(
      (tester.widget<Container>(surfaceFinder).decoration as BoxDecoration)
          .color,
      isNull,
      reason: '无整卡 scrim，图片可从 2dp 行距看到',
    );
    expect(tester.widget<Container>(surfaceFinder).padding, isNull);
    expect(
      tester.getSize(rowFinder.first).width,
      tester.getSize(find.byType(IosGroup)).width,
      reason: '行卡满宽，无 4dp 水平内缩',
    );
    for (final row in tester.widgetList<Material>(rowFinder)) {
      expect(row.color!.a, closeTo(1.0, 0.001),
          reason: 'containerOpacity 默认 100 → 行卡不透明，但只遮行卡区域');
    }

    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      appColumnBackgroundOpacity: 50,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Opacity>(imageOpacity).opacity, closeTo(0.5, 0.001),
        reason: '默认行卡不透明度下，缝隙处图片应可见 50% 差异');

    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      appColumnBackgroundOpacity: 0,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Opacity>(imageOpacity).opacity, 0.0,
        reason: '0% 图片完全透明（缝隙处不再显示图片）');
  });

  testWidgets('图片透明度与行卡不透明度独立叠加（40% / 30%）', (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      containerOpacity: 40,
      appColumnBackgroundOpacity: 30,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final surface = tester.widget<Container>(groupSurface());
    expect((surface.decoration as BoxDecoration).color, isNull);
    final row = tester.widget<Material>(
      find.descendant(of: find.byType(IosGroup), matching: _rowCardFinder),
    );
    expect(row.color!.a, closeTo(0.4, 0.001),
        reason: '行卡 alpha 只受 containerOpacity 控制');
    expect(
      tester
          .widget<Opacity>(
            find.byKey(
              const ValueKey('ios-group-container-background-opacity'),
            ),
          )
          .opacity,
      closeTo(0.3, 0.001),
      reason: '图片 alpha 只受 appColumnBackgroundOpacity 控制',
    );
  });

  testWidgets('默认：100% 行卡不透明、无背景图、无整卡 scrim', (tester) async {
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ios-group-container-background')),
        findsNothing);
    final surface = tester.widget<Container>(groupSurface());
    expect((surface.decoration as BoxDecoration).color, isNull);
    final theme = Theme.of(tester.element(find.byType(IosGroup)));
    final rows = tester.widgetList<Material>(
      find.descendant(of: find.byType(IosGroup), matching: _rowCardFinder),
    );
    expect(rows.length, 1);
    expect(rows.first.color!.a, closeTo(1.0, 0.001));
    expect(rows.first.color, theme.colorScheme.surfaceContainerLow);
  });

  testWidgets('containerOpacity 50：仅行小卡底 alpha=0.5，整卡无底色',
      (tester) async {
    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pumpAndSettle();

    final surface = tester.widget<Container>(groupSurface());
    expect((surface.decoration as BoxDecoration).color, isNull);
    final row = tester.widget<Material>(
      find.descendant(of: find.byType(IosGroup), matching: _rowCardFinder),
    );
    expect(row.color!.a, closeTo(0.5, 0.001));
  });

  testWidgets('透明调色板：行卡 alpha 乘调色板 alpha（100% 保 0.2，50% 变 0.1）',
      (tester) async {
    // [P1 回归] 参考 GlassCard.kt:74-75 为 `it.copy(alpha = it.alpha * alpha)`；
    // 若直接 withValues(alpha: opacity) 会覆盖调色板自身 alpha，把透明主题
    // （surfaceContainerLow=0x33FFFFFF）洗成不透明白卡并盖住容器背景图。
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue).copyWith(
      surfaceContainerLow: const Color(0x33FFFFFF),
    );
    Widget wrapWithPalette() => MaterialApp(
          theme: ThemeData(colorScheme: scheme, useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: IosGroup(children: [IosListTile(title: '行')]),
            ),
          ),
        );

    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 100);
    await tester.pumpWidget(wrapWithPalette());
    await tester.pumpAndSettle();

    var row = tester.widget<Material>(
      find.descendant(of: find.byType(IosGroup), matching: _rowCardFinder),
    );
    expect(row.color!.a, closeTo(0.2, 0.001),
        reason: '100% 时必须保留 surfaceContainerLow 的 0x33 alpha');

    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
    await tester.pumpAndSettle();
    row = tester.widget<Material>(
      find.descendant(of: find.byType(IosGroup), matching: _rowCardFinder),
    );
    expect(row.color!.a, closeTo(0.1, 0.001),
        reason: '50% 应为调色板 alpha 0.2 × 0.5');
  });

  testWidgets('容器背景图总开关：默认关+有路径不渲染；开启渲染；关闭保留路径',
      (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;

    // 默认 false + 有路径 → 不渲染（参考 enableContainerBackgroundImage 默认关）
    uiSettingsListenable.value = UiSettingsState(
      largeContainerBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ios-group-container-background')),
        findsNothing);

    // 开关开 → 渲染
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ios-group-container-background')),
        findsOneWidget);

    // 关闭开关 → 不渲染，但状态里路径仍在（设置页/备份保留）
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: false,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ios-group-container-background')),
        findsNothing);
    expect(
      uiSettingsListenable.value.largeContainerBackgroundImageLight,
      light,
    );
  });

  testWidgets('日/夜各取对应容器背景图；缺失文件回落无图', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    // testWidgets 处于 fake-async zone，真实文件读写必须经 runAsync
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    final dark = (await tester.runAsync(() => storePng('large_dark')))!;
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: light,
      largeContainerBackgroundImageDark: dark,
    );

    await tester.pumpWidget(wrap(brightness: Brightness.light, onTap: null));
    // 真实文件 Image 不走 fake-async 解码，用固定 pump 而非 pumpAndSettle
    // （避免测试环境等待图片流导致不收敛）
    await tester.pump(const Duration(milliseconds: 300));
    var image = tester.widget<Image>(
      find.byKey(const ValueKey('ios-group-container-background')),
    );
    var provider = image.image as ResizeImage;
    expect(
      (provider.imageProvider as FileImage).file.path,
      ThemeBackgroundImageStore.resolveSync(light),
    );
    // [P2.2] 解码限制到「窗口宽高 × DPR」，保持比例且不放大
    expect(provider.width, 1200);
    expect(provider.height, 2000);
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(provider.allowUpscaling, isFalse);

    await tester.pumpWidget(wrap(brightness: Brightness.dark, onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
    image = tester.widget<Image>(
      find.byKey(const ValueKey('ios-group-container-background')),
    );
    provider = image.image as ResizeImage;
    expect(
      (provider.imageProvider as FileImage).file.path,
      ThemeBackgroundImageStore.resolveSync(dark),
    );

    // 夜间图缺失 → 夜间回落为无图（不沿用日间图，不抛错）
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: light,
      largeContainerBackgroundImageDark:
          'theme_backgrounds/large_dark/missing.png',
    );
    await tester.pumpWidget(wrap(brightness: Brightness.dark, onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ios-group-container-background')),
        findsNothing);
    expect(find.text('测试行'), findsOneWidget);
  });

  testWidgets('背景图不拦截点击：行点击仍可触发', (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: light,
    );
    var tapped = false;
    await tester.pumpWidget(wrap(onTap: () => tapped = true));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('ios-group-container-background')),
        findsOneWidget);
    await tester.tap(find.text('测试行'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tapped, isTrue);
  });
}
