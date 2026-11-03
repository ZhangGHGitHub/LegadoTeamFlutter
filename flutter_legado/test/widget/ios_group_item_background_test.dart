// [设置批2b-1b-2b | 2026-11-03] IosGroup 项目（卡片）背景图渲染测试 — 全栈工程师 + UI
//
// 参考语义（GlassCard.kt:29-43,128-160；AppContainerBackground.kt:36-75）：
// - 项目图位于行卡**底色之上、内容之下**，圆角与行卡一致；
// - alpha = glassCardBackgroundOpacity/100（100 覆盖卡面色，0 完全透明），
//   与 containerOpacity（行卡底色 alpha）独立；
// - 与 Large 图共用 enableContainerBackgroundImage 总开关；
// - `.9.png` 用 centerSlice + BoxFit.fill，普通图 BoxFit.cover；
//   解析失败回落普通图。
// 覆盖：默认无图、层序、100/50/0、与 containerOpacity 独立、日/夜、
// 缺失回落、`.9` 切片（项目图与大容器图）、点击不拦截。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/widgets/glass_card_background.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/nine_patch.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

/// 真实 fixture：参考版 release APK res/0x.9.png（12x12，单拉伸区域
/// x/y divs=(4,8)，npTc 为文件序列化格式）与去除 npTc 的源码形态 `.9.png`
const String _fixture0x = 'test/fixtures/nine_patch_0x.9.png';
const String _fixtureNoNpTc =
    'test/fixtures/nine_patch_source_no_nptc.9.png';

void main() {
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legado_ios_item_');
    originalSupportDir = ThemeBackgroundImageStore.supportDir;
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
    resetNinePatchCache();
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() async {
    uiSettingsListenable.value = const UiSettingsState();
    ThemeBackgroundImageStore.supportDir = originalSupportDir;
    ThemeBackgroundImageStore.resetWarmCache();
    resetNinePatchCache();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<String> storeBytes(
    WidgetTester tester,
    String slot, {
    Uint8List? bytes,
    String name = 'pic.png',
  }) async {
    final stored = await tester.runAsync(
      () => ThemeBackgroundImageStore.storeBytes(
        bytes ?? Uint8List.fromList(_pngBytes),
        originalName: name,
        slot: slot,
      ),
    );
    return stored!;
  }

  Widget wrap({
    Brightness brightness = Brightness.light,
    int rows = 1,
    VoidCallback? onTap,
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
                IosListTile(title: rows == 1 ? '测试行' : '测试行$i', onTap: onTap),
            ],
          ),
        ),
      ),
    );
  }

  Finder itemBg(int i) => find.byKey(ValueKey('ios-group-item-background-$i'));
  Finder itemOpacity(int i) =>
      find.byKey(ValueKey('ios-group-item-background-opacity-$i'));
  Finder itemImage(int i) =>
      find.byKey(ValueKey('ios-group-item-background-image-$i'));

  testWidgets('默认：总开关关/无图 → 不建项目图层，行卡仍是单一 Material', (tester) async {
    await tester.pumpWidget(wrap(onTap: null, rows: 2));
    await tester.pumpAndSettle();
    expect(itemBg(0), findsNothing);
    expect(find.byType(GlassCardBackground), findsNothing);
    final rows = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(IosGroup),
            matching: find.byType(Material),
          ),
        )
        .where((m) => m.color != null)
        .toList();
    expect(rows.length, 2);
    for (final row in rows) {
      expect(row.color!.a, closeTo(1.0, 0.001));
    }
  });

  testWidgets('总开关关：即使项目图可用也不渲染', (tester) async {
    final light = await storeBytes(tester, 'item_light');
    uiSettingsListenable.value = UiSettingsState(
      itemBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
    expect(itemBg(0), findsNothing);
  });

  testWidgets('层序：项目图在行卡 Material 内、内容之下，100% 覆盖卡面色', (tester) async {
    final light = await storeBytes(tester, 'item_light');
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    expect(itemBg(0), findsOneWidget);
    // 恒 Stack：第 0 层图片、第 1 层透明 Material 承载行内容
    final stack = tester.widget<Stack>(
      find.ancestor(of: itemBg(0), matching: find.byType(Stack)).first,
    );
    expect(stack.children.length, 2);
    expect(stack.children.first, isA<Positioned>());
    final contentMaterial = stack.children.last as Material;
    expect(contentMaterial.type, MaterialType.transparency,
        reason: '内容层透明 Material 在水波纹/图片之上（100% 仍可见）');

    // 行内容 InkWell 最近 Material 是透明内容层（绘制在项目图之上）
    final inkWell = find
        .descendant(of: find.byType(IosGroup), matching: find.byType(InkWell))
        .first;
    final inkMaterial = tester.widget<Material>(
      find.ancestor(of: inkWell, matching: find.byType(Material)).first,
    );
    expect(inkMaterial.type, MaterialType.transparency,
        reason: '项目图 100% 时水波纹仍画在图片之上');

    // 图片在行卡 Material 内（Material 即卡面底色层）
    final material = tester.widget<Material>(
      find.ancestor(of: itemBg(0), matching: find.byType(Material)).first,
    );
    expect(
      material.color!.a,
      closeTo(1.0, 0.001),
      reason: 'containerOpacity 默认 100，卡面底色不受项目图影响',
    );

    // 内容不在 Opacity 之下（图片不降低文字透明度）
    expect(
      find.ancestor(of: find.text('测试行'), matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(
      tester.widget<Opacity>(itemOpacity(0)).opacity,
      closeTo(1.0, 0.001),
      reason: 'glassCardBackgroundOpacity 默认 100',
    );
    // 图片层不拦截点击
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

    // 普通图：cover，不设 centerSlice
    final image = tester.widget<Image>(itemImage(0));
    expect(image.fit, BoxFit.cover);
    expect(image.centerSlice, isNull);
    expect(image.image, isA<ResizeImage>());
  });

  testWidgets('项目图透明度 100/50/0：只改图片 alpha，图层保留', (tester) async {
    final light = await storeBytes(tester, 'item_light');
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
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
    expect(
      tester.widget<Opacity>(itemOpacity(0)).opacity,
      0.0,
      reason: '0% 完全透明（图层仍在，不改变布局）',
    );
  });

  testWidgets('与 containerOpacity 独立叠加（行卡 40% / 图片 30%）', (tester) async {
    final light = await storeBytes(tester, 'item_light');
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
      containerOpacity: 40,
      glassCardBackgroundOpacity: 30,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final material = tester.widget<Material>(
      find.ancestor(of: itemBg(0), matching: find.byType(Material)).first,
    );
    expect(
      material.color!.a,
      closeTo(0.4, 0.001),
      reason: '卡面 alpha 只受 containerOpacity 控制',
    );
    expect(
      tester.widget<Opacity>(itemOpacity(0)).opacity,
      closeTo(0.3, 0.001),
      reason: '图片 alpha 只受 glassCardBackgroundOpacity 控制',
    );
  });

  testWidgets('日/夜取对应项目图；夜间缺失回落无图（不沿用日间）', (tester) async {
    final light = await storeBytes(tester, 'item_light');
    final dark = await storeBytes(tester, 'item_dark', name: 'dark.png');
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
      itemBackgroundImageDark: dark,
    );

    await tester.pumpWidget(wrap(brightness: Brightness.light, onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
    var image = tester.widget<Image>(itemImage(0));
    expect(
      ((image.image as ResizeImage).imageProvider as FileImage).file.path,
      ThemeBackgroundImageStore.resolveSync(light),
    );

    await tester.pumpWidget(wrap(brightness: Brightness.dark, onTap: null));
    await tester.pump(const Duration(milliseconds: 300));
    image = tester.widget<Image>(itemImage(0));
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
    expect(itemBg(0), findsNothing);
    expect(find.text('测试行'), findsOneWidget);
  });

  testWidgets('真实 `.9.png` fixture：centerSlice=(4,4,8,8) + BoxFit.fill',
      (tester) async {
    final nine = await storeBytes(
      tester,
      'item_light',
      bytes: Uint8List.fromList(File(_fixture0x).readAsBytesSync()),
      name: 'frame.9.png',
    );
    expect(nine, endsWith('.9.png'));
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: nine,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final image = tester.widget<Image>(itemImage(0));
    expect(image.centerSlice, const Rect.fromLTRB(4, 4, 8, 8));
    expect(
      image.fit,
      BoxFit.fill,
      reason: 'centerSlice 必须配 BoxFit.fill（paintImage 断言）',
    );
    expect(
      image.image,
      isA<FileImage>(),
      reason: '`.9` 不走 ResizeImage（切片坐标基于解码像素）',
    );
    expect(tester.widget<Opacity>(itemOpacity(0)).opacity, closeTo(1.0, 0.001));
  });

  testWidgets('源码形态 `.9.png`（无 npTc）→ 回落普通图 cover', (tester) async {
    final sourceNine = await storeBytes(
      tester,
      'item_light',
      bytes: Uint8List.fromList(File(_fixtureNoNpTc).readAsBytesSync()),
      name: 'source.9.png',
    );
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: sourceNine,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final image = tester.widget<Image>(itemImage(0));
    expect(image.centerSlice, isNull);
    expect(image.fit, BoxFit.cover);
    expect(image.image, isA<ResizeImage>());
  });

  testWidgets('大容器背景图同样支持 `.9`（统一 builder）', (tester) async {
    final nine = await storeBytes(
      tester,
      'large_light',
      bytes: Uint8List.fromList(File(_fixture0x).readAsBytesSync()),
      name: 'large.9.png',
    );
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      largeContainerBackgroundImageLight: nine,
    );
    await tester.pumpWidget(wrap(onTap: null));
    await tester.pump(const Duration(milliseconds: 300));

    final image = tester.widget<Image>(
      find.byKey(const ValueKey('ios-group-container-background')),
    );
    expect(image.centerSlice, const Rect.fromLTRB(4, 4, 8, 8));
    expect(image.fit, BoxFit.fill);
    expect(image.image, isA<FileImage>());
  });

  testWidgets('项目图不拦截点击：行点击仍可触发', (tester) async {
    final light = await storeBytes(tester, 'item_light');
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: light,
    );
    var tapped = false;
    await tester.pumpWidget(wrap(onTap: () => tapped = true));
    await tester.pump(const Duration(milliseconds: 300));

    expect(itemBg(0), findsOneWidget);
    await tester.tap(find.text('测试行'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tapped, isTrue);
  });
}
