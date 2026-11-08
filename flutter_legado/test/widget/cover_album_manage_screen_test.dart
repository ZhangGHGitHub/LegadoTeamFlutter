// 封面相册管理页 / 选择 Sheet widget 测试（设置批6b-2）
//
// 覆盖：空态、新建、重命名、删除二次确认（目录清理）、日/夜 Tab、
// 多选导入（注入选择器）、单图删除、当前使用标记、设为默认封面、
// 选择 Sheet 的内置封面/相册/管理入口与返回结果。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/cover_album_manage_screen.dart';
import 'package:flutter_legado/src/screens/cover_album_select_sheet.dart';
import 'package:flutter_legado/src/services/cover_album_image_picker.dart';
import 'package:flutter_legado/src/services/cover_album_store.dart';

Uint8List _png({int r = 0, int g = 0, int b = 0}) {
  final image = img.Image(width: 2, height: 2);
  image.setPixelRgb(0, 0, r, g, b);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CoverAlbumStore.resetForTest();
    CoverAlbumImagePicker.resetForTest();
    temp = await Directory.systemTemp.createTemp('legado_cover_manage_');
    CoverAlbumStore.supportDirOverride = () async => temp;
    CoverAlbumStore.decodeOverride = (_) async => true;
    CoverAlbumStore.isolateOverride = <T>(T Function() action) async =>
        action();
    CoverAlbumStore.bypassSerialization = true;
    await CoverAlbumStore.instance.ensureLoaded();
    coverSettingsListenable.value = CoverSettings.defaults;
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() async {
    CoverAlbumStore.resetForTest();
    CoverAlbumImagePicker.resetForTest();
    coverSettingsListenable.value = CoverSettings.defaults;
    // Image.file 在 Windows 上可能仍持有句柄：先清图片缓存，删除失败
    // 不阻断测试（临时目录由系统清理）。
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  CoverAlbumStore store() => CoverAlbumStore.instance;

  Future<void> pumpManage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: CoverAlbumManageScreen())),
    );
    await tester.pumpAndSettle();
  }

  /// 让真实文件 IO / 引擎解码完成后再刷新帧（FakeAsync 下需 runAsync）
  Future<void> settleAsync(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空态：暂无封面相册', (tester) async {
    await pumpManage(tester);
    expect(find.byKey(const ValueKey('coverAlbumEmpty')), findsOneWidget);
    expect(find.text('暂无封面相册'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('coverAlbumCreateAction')),
      findsOneWidget,
    );
  });

  testWidgets('新建相册：顶栏 + 输入名称', (tester) async {
    await pumpManage(tester);
    await tester.tap(find.byKey(const ValueKey('coverAlbumCreateAction')));
    await tester.pumpAndSettle();
    expect(find.text('新建相册'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('coverAlbumNameField')),
      '我的相册',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('coverAlbumNameConfirm')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('coverAlbumNameConfirm')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await settleAsync(tester);

    expect(store().albums, hasLength(1));
    expect(store().albums.single.name, '我的相册');
    expect(find.text('我的相册'), findsOneWidget);
    expect(find.text('日间 0 · 夜间 0'), findsOneWidget);
  });

  testWidgets('重命名相册', (tester) async {
    final id = await store().createAlbum('旧名称');
    await pumpManage(tester);

    await tester.tap(find.byKey(ValueKey('coverAlbumMenu_$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('coverAlbumRename_$id')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('coverAlbumNameField')),
      '新名称',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('coverAlbumNameConfirm')));
    await tester.pumpAndSettle();
    await settleAsync(tester);

    expect(store().albumById(id)!.name, '新名称');
    expect(find.text('新名称'), findsOneWidget);
  });

  testWidgets('删除相册：二次确认 + 目录清理', (tester) async {
    final id = await store().createAlbum('待删除');
    await store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 8))],
    );
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}'
      '${CoverAlbumStore.rootSubDir}${Platform.pathSeparator}$id',
    );
    expect(dir.existsSync(), isTrue);
    await pumpManage(tester);

    await tester.tap(find.byKey(ValueKey('coverAlbumMenu_$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('coverAlbumDelete_$id')));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除相册「待删除」'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('coverAlbumDeleteConfirm')));
    await tester.pumpAndSettle();
    await settleAsync(tester);
    expect(store().albums, isEmpty);
    expect(dir.existsSync(), isFalse);
    expect(find.byKey(const ValueKey('coverAlbumEmpty')), findsOneWidget);
  });

  testWidgets('日/夜 Tab 空态 + 多选导入（日/夜各自独立）', (tester) async {
    final id = await store().createAlbum('相册');
    await pumpManage(tester);
    await tester.tap(find.byKey(ValueKey('coverAlbumTile_$id')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('coverAlbumImagesEmpty_light')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('coverAlbumNightTab')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('coverAlbumImagesEmpty_dark')),
      findsOneWidget,
    );

    // 夜间导入
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            CoverAlbumImagePick.fromBytes(
              name: 'night.png',
              bytes: _png(r: 30),
            ),
          ],
        );
    await tester.tap(find.byKey(const ValueKey('coverAlbumAddImages')));
    await settleAsync(tester);
    expect(store().albumById(id)!.darkCount, 1);
    expect(store().albumById(id)!.lightCount, 0);
    expect(find.byKey(const ValueKey('coverAlbumGrid_dark')), findsOneWidget);

    // 日间导入（多选两张）
    await tester.tap(find.byKey(const ValueKey('coverAlbumDayTab')));
    await tester.pumpAndSettle();
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            CoverAlbumImagePick.fromBytes(name: 'day1.png', bytes: _png(r: 31)),
            CoverAlbumImagePick.fromBytes(name: 'day2.png', bytes: _png(r: 32)),
          ],
        );
    await tester.tap(find.byKey(const ValueKey('coverAlbumAddImages')));
    await settleAsync(tester);
    expect(store().albumById(id)!.lightCount, 2);
    expect(find.byKey(const ValueKey('coverAlbumGrid_light')), findsOneWidget);
    expect(find.text('日间 2 · 夜间 1'), findsOneWidget);
  });

  testWidgets('单图删除（保留另一侧共用文件）', (tester) async {
    final id = await store().createAlbum('相册');
    final bytes = _png(r: 40);
    await store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'x.png', bytes: bytes)],
    );
    await store().importImages(
      id,
      isDark: true,
      inputs: [CoverAlbumImageInput(displayName: 'x.png', bytes: bytes)],
    );
    final fileName = store().albumById(id)!.lightImages.single.fileName;
    await pumpManage(tester);
    await tester.tap(find.byKey(ValueKey('coverAlbumTile_$id')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('coverAlbumRemoveImage_$fileName')));
    await settleAsync(tester);
    expect(store().albumById(id)!.lightCount, 0);
    expect(store().albumById(id)!.darkCount, 1, reason: '夜间仍引用同一文件');
    expect(
      find.byKey(const ValueKey('coverAlbumImagesEmpty_light')),
      findsOneWidget,
    );
  });

  testWidgets('设为默认封面写 defaultAlbumId 并显示当前使用', (tester) async {
    final id = await store().createAlbum('默认相册');
    await pumpManage(tester);
    await tester.tap(find.byKey(ValueKey('coverAlbumTile_$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coverAlbumSetDefaultButton')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.coverDefaultAlbumId), id);
    expect(
      find.descendant(
        of: find.byType(CoverAlbumEditorSheet),
        matching: find.text('当前使用'),
      ),
      findsOneWidget,
    );

    // 关闭 Sheet 后卡片显示当前使用
    Navigator.of(tester.element(find.byType(CoverAlbumEditorSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.text('当前使用'), findsOneWidget);
  });

  testWidgets('当前默认相册卡片标记当前使用（provider 读取 prefs）', (tester) async {
    final id = await store().createAlbum('当前相册');
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.coverDefaultAlbumId: id,
    });
    await pumpManage(tester);
    expect(find.text('当前使用'), findsOneWidget);
  });

  testWidgets('删除当前默认相册：回落内置封面并清空偏好', (tester) async {
    final id = await store().createAlbum('当前相册');
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.coverDefaultAlbumId: id,
    });
    await pumpManage(tester);
    expect(find.text('当前使用'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('coverAlbumMenu_$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('coverAlbumDelete_$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coverAlbumDeleteConfirm')));
    await tester.pumpAndSettle();
    await settleAsync(tester);

    expect(store().albums, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.coverDefaultAlbumId), '');
    expect(find.byKey(const ValueKey('coverAlbumEmpty')), findsOneWidget);
  });

  testWidgets('导入失败在 Sheet 内状态行可见（不被 Sheet 遮挡）', (tester) async {
    final id = await store().createAlbum('相册');
    await pumpManage(tester);
    await tester.tap(find.byKey(ValueKey('coverAlbumTile_$id')));
    await tester.pumpAndSettle();

    CoverAlbumStore.decodeOverride = (_) async => false;
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            CoverAlbumImagePick.fromBytes(name: 'bad.png', bytes: _png(r: 77)),
          ],
        );
    await tester.tap(find.byKey(const ValueKey('coverAlbumAddImages')));
    await settleAsync(tester);

    expect(find.byKey(const ValueKey('coverAlbumStatus')), findsOneWidget);
    expect(find.textContaining('1 张跳过'), findsOneWidget);
    expect(find.textContaining('不是可解码的图片'), findsOneWidget);
  });

  testWidgets('导入忙态禁用单图删除，完成后恢复', (tester) async {
    final id = await store().createAlbum('相册');
    final existing = _png(r: 88);
    await store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: existing)],
    );
    final fileName = store().albumById(id)!.lightImages.single.fileName;
    await pumpManage(tester);
    await tester.tap(find.byKey(ValueKey('coverAlbumTile_$id')));
    await tester.pumpAndSettle();

    final gate = Completer<Uint8List>();
    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            CoverAlbumImagePick(
              name: 'b.png',
              size: existing.length,
              read: () => gate.future,
            ),
          ],
        );
    await tester.tap(find.byKey(const ValueKey('coverAlbumAddImages')));
    await tester.pump();
    InkWell removeButton() => tester.widget<InkWell>(
      find.byKey(ValueKey('coverAlbumRemoveImage_$fileName')),
    );
    expect(removeButton().onTap, isNull, reason: '忙态禁止删除');

    gate.complete(_png(r: 89));
    await settleAsync(tester);
    expect(removeButton().onTap, isNotNull);
    expect(store().albumById(id)!.lightCount, 2);
  });

  testWidgets('重复导入同图提示已存在', (tester) async {
    final id = await store().createAlbum('相册');
    final bytes = _png(r: 90);
    await store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: bytes)],
    );
    await pumpManage(tester);
    await tester.tap(find.byKey(ValueKey('coverAlbumTile_$id')));
    await tester.pumpAndSettle();

    CoverAlbumImagePicker.pickOverride = (maxBytes) async =>
        CoverAlbumImagePickBatch(
          picks: [
            CoverAlbumImagePick.fromBytes(name: 'same.png', bytes: bytes),
          ],
        );
    await tester.tap(find.byKey(const ValueKey('coverAlbumAddImages')));
    await settleAsync(tester);

    expect(find.byKey(const ValueKey('coverAlbumStatus')), findsOneWidget);
    expect(find.textContaining('已存在'), findsOneWidget);
    expect(store().albumById(id)!.lightCount, 1);
  });

  testWidgets('选择 Sheet：内置封面 + 相册数量 + 管理入口', (tester) async {
    final id = await store().createAlbum('相册甲');
    await store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 5))],
    );
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      defaultAlbumId: id,
    );
    bool managed = false;
    CoverAlbumSelection? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const ValueKey('openSheet'),
                onPressed: () async {
                  result = await CoverAlbumSelectSheet.show(
                    context,
                    onManage: () => managed = true,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('openSheet')));
    await tester.pumpAndSettle();

    expect(find.text('选择封面相册'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('coverAlbumBuiltinOption')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('coverAlbumOption_$id')), findsOneWidget);
    expect(find.text('日间 1 · 夜间 0'), findsOneWidget);
    expect(find.byKey(ValueKey('coverAlbumOptionCheck_$id')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('coverAlbumOption_$id')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.albumId, id);

    // 再次打开测试管理入口（回调触发后关闭 Sheet）
    await tester.tap(find.byKey(const ValueKey('openSheet')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coverAlbumManageAction')));
    await tester.pumpAndSettle();
    expect(managed, isTrue);
    expect(find.text('选择封面相册'), findsNothing);
  });
}
