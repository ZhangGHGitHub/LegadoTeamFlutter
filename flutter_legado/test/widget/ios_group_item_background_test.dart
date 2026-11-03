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
import 'package:image/image.dart' as img;

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/widgets/glass_card_background.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/nine_patch.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

/// ---- synthetic `.9.png`（npTc 单拉伸区域 2,2..7,7）----

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Iterable<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _pngChunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final bytes = Uint8List(8 + data.length + 4);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, data.length, Endian.big);
  bytes.setRange(4, 8, typeBytes);
  bytes.setRange(8, 8 + data.length, data);
  view.setUint32(
    8 + data.length,
    _crc32(<int>[...typeBytes, ...data]),
    Endian.big,
  );
  return bytes;
}

Uint8List _ninePatchPng() {
  final image = img.Image(width: 9, height: 9);
  img.fill(image, color: img.ColorRgb8(180, 40, 40));
  final base = Uint8List.fromList(img.encodePng(image));
  final ihdrLength = ByteData.sublistView(base, 8, 12).getUint32(0, Endian.big);
  final ihdrEnd = 8 + 12 + ihdrLength;
  final npTc = Uint8List(20);
  final view = ByteData.sublistView(npTc);
  npTc[0] = 1;
  npTc[1] = 2;
  npTc[2] = 2;
  view.setInt32(4, 2, Endian.little);
  view.setInt32(8, 7, Endian.little);
  view.setInt32(12, 2, Endian.little);
  view.setInt32(16, 7, Endian.little);
  final out = BytesBuilder(copy: false)
    ..add(base.sublist(0, ihdrEnd))
    ..add(_pngChunk('npTc', npTc))
    ..add(base.sublist(ihdrEnd));
  return out.toBytes();
}

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
    final rows = tester.widgetList<Material>(
      find.descendant(
        of: find.byType(IosGroup),
        matching: find.byType(Material),
      ),
    );
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
    // 最近的 Stack 是行卡内层：第 0 层图片、第 1 层行内容
    final stack = tester.widget<Stack>(
      find.ancestor(of: itemBg(0), matching: find.byType(Stack)).first,
    );
    expect(stack.children.length, 2);
    expect(stack.children.first, isA<Positioned>());
    expect(stack.children.last, isA<IosListTile>());

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

  testWidgets('`.9.png` 项目图：centerSlice + BoxFit.fill（不模糊）', (tester) async {
    final nine = await storeBytes(
      tester,
      'item_light',
      bytes: _ninePatchPng(),
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
    expect(image.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
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

  testWidgets('`.9.png` 解析失败（无 npTc）→ 回落普通图 cover', (tester) async {
    final fakeNine = await storeBytes(
      tester,
      'item_light',
      bytes: Uint8List.fromList(_pngBytes),
      name: 'fake.9.png',
    );
    uiSettingsListenable.value = UiSettingsState(
      enableContainerBackgroundImage: true,
      itemBackgroundImageLight: fakeNine,
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
      bytes: _ninePatchPng(),
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
    expect(image.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
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
