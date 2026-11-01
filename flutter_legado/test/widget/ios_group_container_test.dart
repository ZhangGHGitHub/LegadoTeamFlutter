// [设置批2b-1a | 2026-11-01] IosGroup 容器背景图/不透明度 widget 测试 — 全栈工程师
//
// 覆盖：默认 100% 不透明度无背景图（零视觉变化）；不透明度作用于分组底与
// 行小卡底；日/夜各取对应背景图；文件缺失回落；背景图不拦截点击。
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

  Widget wrap({Brightness brightness = Brightness.light, required VoidCallback? onTap}) {
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
              IosListTile(title: '测试行', onTap: onTap),
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

  testWidgets('容器图层序：图片在分组底色之下并同圆角裁剪（100% 无缝隙）',
      (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final stack = tester.widget<Stack>(groupStack());
    expect(stack.children.length, 2);
    expect(stack.children.first, isA<Positioned>(),
        reason: '背景图必须是 Stack 第 0 层（分组底色之下）');
    expect(stack.children.last, isA<Container>(),
        reason: '分组底色/行小卡必须在背景图之上');

    // 同一 16dp 圆角裁剪
    final clip = tester.widget<ClipRRect>(
      find.ancestor(of: groupStack(), matching: find.byType(ClipRRect)).first,
    );
    expect(clip.borderRadius, BorderRadius.circular(16));

    // 底色铺满整卡：与背景图同尺寸，100% 时不透明 → 图片被完全覆盖，
    // 4dp 分组 padding 与 2dp 行间距都落在底色区域，无原图缝隙。
    final imageFinder =
        find.byKey(const ValueKey('ios-group-container-background'));
    expect(imageFinder, findsOneWidget);
    final surface = tester.widget<Container>(groupSurface());
    expect(
      (surface.decoration as BoxDecoration).color!.a,
      closeTo(1.0, 0.001),
    );
    expect(
      tester.getSize(groupSurface()),
      tester.getSize(imageFinder),
      reason: '底色与背景图同尺寸（整卡覆盖）',
    );
    expect(
      tester.getSize(groupSurface()),
      tester.getSize(find.byType(IosGroup)),
      reason: '底色铺满分组卡（含 4dp padding 区域）',
    );
  });

  testWidgets('50%：整卡单一底色 scrim 覆盖图片，缝隙不露原图', (tester) async {
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      containerOpacity: 50,
      largeContainerBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final surface = tester.widget<Container>(groupSurface());
    expect(
      (surface.decoration as BoxDecoration).color!.a,
      closeTo(0.5, 0.001),
    );
    // 单一整卡 scrim：底色与图片同尺寸且位于图片之上（Stack 顺序见上一用例）
    expect(
      tester.getSize(groupSurface()),
      tester.getSize(
        find.byKey(const ValueKey('ios-group-container-background')),
      ),
    );
    final imageRect = tester.getRect(
      find.byKey(const ValueKey('ios-group-container-background')),
    );
    final surfaceRect = tester.getRect(groupSurface());
    expect(surfaceRect, imageRect,
        reason: '50% 时缝隙与卡面同属一个 scrim，不再有全强度原图线');
  });

  testWidgets('默认：100% 不透明、无背景图，视觉与改造前等价', (tester) async {
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ios-group-container-background')),
        findsNothing);
    final surface = tester.widget<Container>(groupSurface());
    expect(
      (surface.decoration as BoxDecoration).color!.a,
      closeTo(1.0, 0.001),
    );
    final theme = Theme.of(tester.element(find.byType(IosGroup)));
    final rows = tester.widgetList<Material>(
      find.descendant(of: find.byType(IosGroup), matching: find.byType(Material)),
    );
    expect(rows.length, 1);
    expect(rows.first.color!.a, closeTo(1.0, 0.001));
    expect(rows.first.color, theme.colorScheme.surfaceContainerLow);
  });

  testWidgets('容器不透明度 50：分组底与行小卡底 alpha=0.5', (tester) async {
    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pumpAndSettle();

    final surface = tester.widget<Container>(groupSurface());
    expect(
      (surface.decoration as BoxDecoration).color!.a,
      closeTo(0.5, 0.001),
    );
    final row = tester.widget<Material>(
      find.descendant(of: find.byType(IosGroup), matching: find.byType(Material)),
    );
    expect(row.color!.a, closeTo(0.5, 0.001));
  });

  testWidgets('透明调色板：不透明度乘 alpha（100% 保 0.2/0.0，50% 变 0.1/0.0）',
      (tester) async {
    // [P1 回归] 参考 GlassCard.kt:74-75 为 `it.copy(alpha = it.alpha * alpha)`；
    // 若直接 withValues(alpha: opacity) 会覆盖调色板自身 alpha，把透明主题
    // （surfaceContainer=0x33FFFFFF、surfaceContainerLow=0x00FFFFFF）洗成
    // 不透明白卡并盖住容器背景图。
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue).copyWith(
      surfaceContainer: const Color(0x33FFFFFF),
      surfaceContainerLow: const Color(0x00FFFFFF),
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

    var surface = tester.widget<Container>(groupSurface());
    expect(
      (surface.decoration as BoxDecoration).color!.a,
      closeTo(0.2, 0.001),
      reason: '100% 时必须保留 surfaceContainer 的 0x33 alpha',
    );
    var row = tester.widget<Material>(
      find.descendant(of: find.byType(IosGroup), matching: find.byType(Material)),
    );
    expect(row.color!.a, closeTo(0.0, 0.001),
        reason: '100% 时必须保留 surfaceContainerLow 的全透明');

    uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
    await tester.pumpAndSettle();
    surface = tester.widget<Container>(groupSurface());
    expect(
      (surface.decoration as BoxDecoration).color!.a,
      closeTo(0.1, 0.001),
      reason: '50% 应为调色板 alpha 0.2 × 0.5',
    );
    row = tester.widget<Material>(
      find.descendant(of: find.byType(IosGroup), matching: find.byType(Material)),
    );
    expect(row.color!.a, closeTo(0.0, 0.001),
        reason: '0.0 × 0.5 仍为 0.0');
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
