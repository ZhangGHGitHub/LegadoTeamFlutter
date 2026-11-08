// BookCover 相册封面渲染测试（设置批6b-2）
//
// 覆盖：defaultAlbumId 有效时按书名种子稳定取图、日夜列表独立、
// 空书名取第 0 张、相册缺失/夜间为空/文件缺失回落内置默认图 + 文字、
// useDefaultCover 与相册图共存（不发起网络请求）、相册图带 cacheWidth。
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/cover_album_store.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';

Uint8List _png({int r = 0, int g = 0, int b = 0}) {
  final image = img.Image(width: 4, height: 4);
  image.setPixelRgb(0, 0, r, g, b);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String albumId;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CoverAlbumStore.resetForTest();
    temp = await Directory.systemTemp.createTemp('legado_book_cover_album_');
    CoverAlbumStore.supportDirOverride = () async => temp;
    CoverAlbumStore.decodeOverride = (_) async => true;
    CoverAlbumStore.isolateOverride = <T>(T Function() action) async =>
        action();
    CoverAlbumStore.bypassSerialization = true;
    await CoverAlbumStore.instance.ensureLoaded();
    albumId = await CoverAlbumStore.instance.createAlbum('相册');
    // 日间两张（颜色不同 → 哈希不同），夜间一张
    await CoverAlbumStore.instance.importImages(
      albumId,
      isDark: false,
      inputs: [
        CoverAlbumImageInput(displayName: 'day1.png', bytes: _png(r: 10)),
        CoverAlbumImageInput(displayName: 'day2.png', bytes: _png(r: 20)),
      ],
    );
    await CoverAlbumStore.instance.importImages(
      albumId,
      isDark: true,
      inputs: [
        CoverAlbumImageInput(displayName: 'night.png', bytes: _png(r: 90)),
      ],
    );
    coverSettingsListenable.value = CoverSettings.defaults;
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() async {
    CoverAlbumStore.resetForTest();
    coverSettingsListenable.value = CoverSettings.defaults;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 图片句柄释放延迟：临时目录由系统清理
    }
  });

  CoverAlbumStore store() => CoverAlbumStore.instance;

  Future<void> pumpCover(
    WidgetTester tester, {
    String? bookName,
    String? bookAuthor,
    String? coverUrl,
    bool dark = false,
    bool useDefaultCover = false,
    String? albumIdOverride,
    String? darkAlbumId,
  }) async {
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      defaultAlbumId: albumIdOverride ?? albumId,
      defaultAlbumIdDark: darkAlbumId,
      useDefaultCover: useDefaultCover,
    );
    await tester.pumpWidget(
      MaterialApp(
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: BookCover(
              coverUrl: coverUrl,
              bookName: bookName,
              bookAuthor: bookAuthor,
              width: 80,
              height: 110,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // MaterialApp 主题切换有 200ms 动画；跳过动画后再断言 Brightness
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      Theme.of(tester.element(find.byType(BookCover))).brightness,
      dark ? Brightness.dark : Brightness.light,
    );
  }

  FileImage fileImageOf(Image widget) {
    final provider = widget.image;
    if (provider is ResizeImage) return provider.imageProvider as FileImage;
    return provider as FileImage;
  }

  String albumImagePath(WidgetTester tester) {
    final widget = tester.widget<Image>(
      find.byKey(const ValueKey('bookCoverAlbumImage')),
    );
    return fileImageOf(widget).file.path;
  }

  testWidgets('书名种子稳定：同书名同图，日夜取各自列表', (tester) async {
    await pumpCover(tester, bookName: 'a');
    expect(find.byKey(const ValueKey('bookCoverAlbumImage')), findsOneWidget);
    expect(
      albumImagePath(tester),
      store().imagePathForAlbum(albumId, isDark: false, seed: 'a'),
    );
    // 文字叠层仍在（默认显示书名/作者）
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    final image = tester.widget<Image>(
      find.byKey(const ValueKey('bookCoverAlbumImage')),
    );
    expect(image.image, isA<ResizeImage>(), reason: '相册大图应带 cacheWidth 缩略解码');

    // 同书名重建（新 Widget 树）仍取同一张
    final first = albumImagePath(tester);
    await pumpCover(tester, bookName: 'a');
    expect(albumImagePath(tester), first);

    // 夜间使用夜间列表（仅一张）
    await pumpCover(tester, bookName: 'a', dark: true);
    expect(
      albumImagePath(tester),
      store().imagePathForAlbum(albumId, isDark: true, seed: 'a'),
    );
    expect(find.byKey(const ValueKey('bookCoverDefaultNight')), findsNothing);
  });

  testWidgets('不同书名按哈希取不同图；空书名稳定', (tester) async {
    await pumpCover(tester, bookName: 'a');
    final aPath = albumImagePath(tester);
    final aIndex = CoverAlbumStore.coverAlbumSeedIndex('a', 2);
    final otherSeed = <String>['b', 'c', 'd', 'e', 'f'].firstWhere(
      (seed) => CoverAlbumStore.coverAlbumSeedIndex(seed, 2) != aIndex,
    );
    await pumpCover(tester, bookName: otherSeed);
    final bPath = albumImagePath(tester);
    expect(bPath, isNot(aPath), reason: '不同 seed 落不同下标');
    expect(aPath, isNot(store().albumById(albumId)!.lightImages.first.path));

    final lightImages = store().albumById(albumId)!.lightImages;
    final emptyIndex = CoverAlbumStore.coverAlbumSeedIndex(
      '',
      lightImages.length,
    );
    await pumpCover(tester, bookName: null);
    expect(albumImagePath(tester), lightImages[emptyIndex].path);
    await pumpCover(tester, bookName: '');
    expect(albumImagePath(tester), lightImages[emptyIndex].path);
  });

  testWidgets('相册不存在/夜间列表为空：回落内置默认封面 + 夜间叠层', (tester) async {
    await pumpCover(tester, bookName: 'a', albumIdOverride: 'missing-album');
    expect(find.byKey(const ValueKey('bookCoverAlbumImage')), findsNothing);
    expect(find.byKey(const ValueKey('bookCoverDefault')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);

    // 删除夜间图片后夜间列表为空 → 内置默认封面
    final night = store().albumById(albumId)!.darkImages.single;
    await store().removeImage(albumId, isDark: true, fileName: night.fileName);
    await tester.pump();
    await pumpCover(tester, bookName: 'a', dark: true);
    expect(find.byKey(const ValueKey('bookCoverAlbumImage')), findsNothing);
    expect(find.byKey(const ValueKey('bookCoverDefaultNight')), findsOneWidget);
  });

  testWidgets('相册文件缺失：errorBuilder 回落内置默认封面', (tester) async {
    final path = store().imagePathForAlbum(albumId, isDark: false, seed: 'a')!;
    File(path).deleteSync();
    await pumpCover(tester, bookName: 'a');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookCoverAlbumImage')), findsNothing);
    expect(find.byKey(const ValueKey('bookCoverDefault')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
  });

  testWidgets('书名为空时以作者作为种子（参考 name ?? author）', (tester) async {
    await pumpCover(tester, bookName: null, bookAuthor: '作者甲');
    expect(
      albumImagePath(tester),
      store().imagePathForAlbum(albumId, isDark: false, seed: '作者甲'),
    );
  });

  testWidgets('defaultAlbumIdDark 优先于 defaultAlbumId（夜间）', (tester) async {
    final otherId = await store().createAlbum('夜间相册');
    await store().importImages(
      otherId,
      isDark: true,
      inputs: [CoverAlbumImageInput(displayName: 'n.png', bytes: _png(r: 99))],
    );
    await pumpCover(tester, bookName: 'a', dark: true, darkAlbumId: otherId);
    expect(
      albumImagePath(tester),
      store().imagePathForAlbum(otherId, isDark: true, seed: 'a'),
    );
  });

  testWidgets('相册图片变化后 revision 触发默认封面重建', (tester) async {
    await pumpCover(tester, bookName: 'a');
    final before = albumImagePath(tester);
    final fileName = store()
        .albumById(albumId)!
        .lightImages
        .firstWhere((image) => image.path == before)
        .fileName;
    await store().removeImage(albumId, isDark: false, fileName: fileName);
    await tester.pump();
    final after = albumImagePath(tester);
    expect(after, isNot(before), reason: '列表变化后换用剩余图片');
    expect(after, store().albumById(albumId)!.lightImages.single.path);
  });

  testWidgets('图片内容损坏：errorBuilder 回落内置默认封面', (tester) async {
    final path = store().imagePathForAlbum(albumId, isDark: false, seed: 'a')!;
    File(path).writeAsBytesSync(<int>[0, 1, 2, 3, 4]);
    await pumpCover(tester, bookName: 'a');
    // 直接调用 Image.file 装配的 errorBuilder（引擎解码失败的真实回落路径）
    final imageWidget = tester.widget<Image>(
      find.byKey(const ValueKey('bookCoverAlbumImage')),
    );
    expect(imageWidget.errorBuilder, isNotNull);
    final fallback = imageWidget.errorBuilder!(
      tester.element(find.byKey(const ValueKey('bookCoverAlbumImage'))),
      'decode error',
      StackTrace.empty,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: fallback)),
      ),
    );
    expect(
      find.byKey(const ValueKey('bookCoverAlbumFallback')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('bookCoverText')), findsNothing);
  });

  testWidgets('总是使用默认封面：相册图生效且不创建网络封面', (tester) async {
    await pumpCover(
      tester,
      bookName: 'a',
      coverUrl: 'https://example.com/cover.jpg',
      useDefaultCover: true,
    );
    expect(find.byKey(const ValueKey('bookCoverAlbumImage')), findsOneWidget);
    // 总是默认封面：不创建网络图片组件（相册图不联网）
    expect(find.byType(CachedNetworkImage), findsNothing);
  });
}
