// [设置批2b-1a | 2026-11-01] 全局背景图层（日/夜虚化）widget 测试 — 全栈工程师
//
// 覆盖：无图/缺图不生成图片层（回落）；blur=0 不产生 ImageFiltered 开销；
// blur>0 时 ImageFiltered 只包背景 Image，内容/文字不在滤镜内；
// 背景图「无→有」切换不重建应用子树（恒定 Stack 槽位，修既有登记风险）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/theme_background_layer.dart';

/// 1x1 透明 PNG（真实可解码）
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static int initCount = 0;

  @override
  void initState() {
    super.initState();
    initCount++;
  }

  @override
  Widget build(BuildContext context) => const Text('内容');
}

void main() {
  late Directory temp;
  late File png;

  setUp(() async {
    _ProbeState.initCount = 0;
    temp = await Directory.systemTemp.createTemp('legado_bg_layer_');
    png = File('${temp.path}${Platform.pathSeparator}bg.png');
    await png.writeAsBytes(_pngBytes);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Widget wrap({
    required String path,
    int blurRadius = 0,
    Widget child = const Text('内容'),
  }) {
    return MaterialApp(
      home: ThemeBackgroundLayer(
        path: path,
        blurRadius: blurRadius,
        child: Scaffold(body: Center(child: child)),
      ),
    );
  }

  testWidgets('无背景图：不绘制图片、不产生滤镜，内容正常', (tester) async {
    await tester.pumpWidget(wrap(path: ''));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('背景图缺失：按无图回落，不抛错', (tester) async {
    await tester.pumpWidget(
      wrap(path: '${temp.path}${Platform.pathSeparator}missing.png', blurRadius: 30),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('blur=0：绘制背景图但不加 ImageFiltered', (tester) async {
    await tester.pumpWidget(wrap(path: png.path));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('blur>0：ImageFiltered 只包背景图，内容/文字不在滤镜内', (tester) async {
    await tester.pumpWidget(wrap(path: png.path, blurRadius: 24));
    await tester.pumpAndSettle();

    expect(find.byType(ImageFiltered), findsOneWidget);
    final filtered = tester.widget<ImageFiltered>(find.byType(ImageFiltered));
    expect(
      filtered.imageFilter,
      ui.ImageFilter.blur(
        sigmaX: 24,
        sigmaY: 24,
        tileMode: TileMode.clamp,
      ),
      reason: '半径应逐字映射到 ImageFilter sigma',
    );
    expect(
      find.descendant(
        of: find.byType(ImageFiltered),
        matching: find.byType(Image),
      ),
      findsOneWidget,
      reason: '滤镜内只有背景图',
    );
    expect(
      find.descendant(
        of: find.byType(ImageFiltered),
        matching: find.text('内容'),
      ),
      findsNothing,
      reason: '内容/文字不得被虚化',
    );
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('背景图「无→有」「有→无」切换不重建应用子树', (tester) async {
    await tester.pumpWidget(wrap(path: '', child: const _Probe()));
    await tester.pumpAndSettle();
    expect(_ProbeState.initCount, 1);

    await tester.pumpWidget(wrap(path: png.path, child: const _Probe()));
    await tester.pumpAndSettle();
    expect(_ProbeState.initCount, 1, reason: '加图不应重建 child 子树');

    await tester.pumpWidget(wrap(path: '', child: const _Probe()));
    await tester.pumpAndSettle();
    expect(_ProbeState.initCount, 1, reason: '去图不应重建 child 子树');
  });
}
