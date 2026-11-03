// [设置批2b-1b-2b | 2026-11-03] 设置首页手写卡片项目背景图测试 — 全栈工程师 + UI
//
// 设置首页入口卡为手写 Material（16dp 圆角、10dp 行距），不经 IosGroup；
// 本文件验证 [设置批2b-1b-2b] 按 GlassCard Item 语义叠加项目图：
// 图片在卡面底色之上、入口内容之下，16dp 圆角裁剪，alpha 由
// glassCardBackgroundOpacity 控制（与 containerOpacity 独立），总开关
// enableContainerBackgroundImage 关闭时不渲染。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/widgets/glass_card_background.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

void main() {
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legado_home_item_');
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

  Future<String> storeItem(
    WidgetTester tester, {
    String slot = 'item_light',
    String name = 'pic.png',
  }) async {
    final stored = await tester.runAsync(
      () => ThemeBackgroundImageStore.storeBytes(
        Uint8List.fromList(_pngBytes),
        originalName: name,
        slot: slot,
      ),
    );
    return stored!;
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: brightness,
          ),
          useMaterial3: true,
        ),
        home: const SettingsHomeScreen(),
      ),
    );
    // 真实文件图片解码不走 fake-async，固定 pump 避免等待图片流
    await tester.pump(const Duration(milliseconds: 300));
  }

  Finder itemBg(int i) =>
      find.byKey(ValueKey('settings-home-item-background-$i'));
  Finder itemOpacity(int i) =>
      find.byKey(ValueKey('settings-home-item-background-opacity-$i'));

  List<Material> cardMaterials(WidgetTester tester) => tester
      .widgetList<Material>(
        find.descendant(
          of: find.byType(SettingsHomeScreen),
          matching: find.byType(Material),
        ),
      )
      .where((m) => m.borderRadius == BorderRadius.circular(16))
      .toList();

  testWidgets('默认：无项目图，8 张卡不建图片层', (tester) async {
    await pumpPage(tester);
    expect(find.byType(GlassCardBackground), findsNothing);
    expect(cardMaterials(tester).length, 8);
  });

  testWidgets('总开关关：有可用项目图也不渲染', (tester) async {
    final light = await storeItem(tester);
    uiSettingsListenable.value = UiSettingsState(
      itemBackgroundImageLight: light,
    );
    await pumpPage(tester);
    expect(find.byType(GlassCardBackground), findsNothing);
  });

  testWidgets('层序：图片在卡面 Material 内、入口内容之下，8 卡各有图层', (tester) async {
    final light = await storeItem(tester);
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
    );
    await pumpPage(tester);

    expect(find.byType(GlassCardBackground), findsNWidgets(8));
    final stack = tester.widget<Stack>(
      find.ancestor(of: itemBg(0), matching: find.byType(Stack)).first,
    );
    expect(stack.children.length, 2);
    expect(stack.children.first, isA<Positioned>());
    expect(stack.children.last, isA<InkWell>());

    final material = tester.widget<Material>(
      find.ancestor(of: itemBg(0), matching: find.byType(Material)).first,
    );
    expect(
      material.color!.a,
      closeTo(1.0, 0.001),
      reason: 'containerOpacity 默认 100',
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find.descendant(
              of: itemBg(0),
              matching: find.byType(IgnorePointer),
            ),
          )
          .ignoring,
      isTrue,
    );
    // 文字不因图片层整体变淡
    expect(
      find.ancestor(of: find.text('外观'), matching: find.byType(Opacity)),
      findsNothing,
    );
  });

  testWidgets('项目图透明度 100/50/0 即时生效', (tester) async {
    final light = await storeItem(tester);
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
    );
    await pumpPage(tester);
    expect(tester.widget<Opacity>(itemOpacity(0)).opacity, closeTo(1.0, 0.001));

    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
      glassCardBackgroundOpacity: 50,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Opacity>(itemOpacity(0)).opacity, closeTo(0.5, 0.001));

    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
      glassCardBackgroundOpacity: 0,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Opacity>(itemOpacity(0)).opacity, 0.0);
  });

  testWidgets('与 containerOpacity 独立（卡面 50% / 图片 30%）', (tester) async {
    final light = await storeItem(tester);
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
      containerOpacity: 50,
      glassCardBackgroundOpacity: 30,
    );
    await pumpPage(tester);

    final material = tester.widget<Material>(
      find.ancestor(of: itemBg(0), matching: find.byType(Material)).first,
    );
    expect(material.color!.a, closeTo(0.5, 0.001));
    expect(tester.widget<Opacity>(itemOpacity(0)).opacity, closeTo(0.3, 0.001));
  });

  testWidgets('日/夜各取对应项目图；夜间缺失则不再沿用日间图', (tester) async {
    final light = await storeItem(tester);
    final dark = await storeItem(tester, slot: 'item_dark', name: 'dark.png');
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
      itemBackgroundImageDark: dark,
    );
    await pumpPage(tester);
    var image = tester.widget<Image>(
      find.byKey(const ValueKey('settings-home-item-background-image-0')),
    );
    expect(
      ((image.image as ResizeImage).imageProvider as FileImage).file.path,
      ThemeBackgroundImageStore.resolveSync(light),
    );

    await pumpPage(tester, brightness: Brightness.dark);
    image = tester.widget<Image>(
      find.byKey(const ValueKey('settings-home-item-background-image-0')),
    );
    expect(
      ((image.image as ResizeImage).imageProvider as FileImage).file.path,
      ThemeBackgroundImageStore.resolveSync(dark),
    );

    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
      itemBackgroundImageDark: 'theme_backgrounds/item_dark/missing.png',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(GlassCardBackground), findsNothing);
    expect(find.text('外观'), findsOneWidget);
  });
}
