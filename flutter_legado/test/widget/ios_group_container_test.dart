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
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.clipBehavior == Clip.antiAlias &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).borderRadius ==
                  BorderRadius.circular(16),
        ),
      );

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

  testWidgets('日/夜各取对应容器背景图；缺失文件回落无图', (tester) async {
    // testWidgets 处于 fake-async zone，真实文件读写必须经 runAsync
    final light = (await tester.runAsync(() => storePng('large_light')))!;
    final dark = (await tester.runAsync(() => storePng('large_dark')))!;
    uiSettingsListenable.value = UiSettingsState(
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
    expect(
      (image.image as FileImage).file.path,
      ThemeBackgroundImageStore.resolveSync(light),
    );

    await tester.pumpWidget(wrap(brightness: Brightness.dark, onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
    image = tester.widget<Image>(
      find.byKey(const ValueKey('ios-group-container-background')),
    );
    expect(
      (image.image as FileImage).file.path,
      ThemeBackgroundImageStore.resolveSync(dark),
    );

    // 夜间图缺失 → 夜间回落为无图（不沿用日间图，不抛错）
    uiSettingsListenable.value = UiSettingsState(
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
