// 封面相册存储单测（设置批6b-2）
//
// 覆盖：新建/重命名/删除（目录清理）、重名、SHA-256 命名与去重、
// 日/夜共用文件删除保护、原子写无 tmp 残留、损坏索引回落、索引路径
// 穿越防护、旧 defaultCover/defaultCoverDark 逗号路径迁移与幂等标记、
// 大图/空/非图片拒绝、书名种子稳定性、备份排除与恢复后默认相册 ID
// 有效性清理。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/services/cover_album_store.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

/// 可解码的 PNG（颜色不同 → 内容哈希不同）
Uint8List _png({int r = 0, int g = 0, int b = 0}) {
  final image = img.Image(width: 2, height: 2);
  image.setPixelRgb(0, 0, r, g, b);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  String rootPath() => '${temp.path}${Platform.pathSeparator}cover_albums';

  Directory rootDir() => Directory(rootPath());

  File indexFile() => File(
    '${rootPath()}${Platform.pathSeparator}'
    '${CoverAlbumStore.indexFileName}',
  );

  Map<String, dynamic> readIndex() =>
      jsonDecode(indexFile().readAsStringSync()) as Map<String, dynamic>;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CoverAlbumStore.resetForTest();
    temp = await Directory.systemTemp.createTemp('legado_cover_album_');
    CoverAlbumStore.supportDirOverride = () async => temp;
    coverSettingsListenable.value = CoverSettings.defaults;
  });

  tearDown(() async {
    CoverAlbumStore.resetForTest();
    coverSettingsListenable.value = CoverSettings.defaults;
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  CoverAlbumStore store() => CoverAlbumStore.instance;

  Future<CoverAlbumImportResult> importBytes(
    String albumId, {
    required bool isDark,
    required List<int> bytes,
    String name = 'cover.png',
  }) {
    return store().importImages(
      albumId,
      isDark: isDark,
      inputs: [
        CoverAlbumImageInput(
          displayName: name,
          bytes: Uint8List.fromList(bytes),
        ),
      ],
    );
  }

  group('相册增删改', () {
    test('新建：名称去空白、ID 安全、索引 formatVersion=2 且只存文件名', () async {
      final id = await store().createAlbum('  相册A  ');
      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      final album = store().albumById(id)!;
      expect(album.name, '相册A');
      expect(
        Directory('${rootPath()}${Platform.pathSeparator}$id').existsSync(),
        isTrue,
      );

      final index = readIndex();
      expect(index['formatVersion'], CoverAlbumStore.formatVersion);
      final albums = index['albums'] as List;
      expect(albums, hasLength(1));
      final stored = albums.single as Map;
      expect(stored['id'], id);
      expect(stored['name'], '相册A');
      expect(stored['lightImages'], isEmpty);
      expect(stored['darkImages'], isEmpty);
      // 索引不含绝对路径
      expect(jsonEncode(index).contains(temp.path), isFalse);
    });

    test('重名允许（参考版不限制）；ID 不同', () async {
      final first = await store().createAlbum('同名');
      final second = await store().createAlbum('同名');
      expect(first, isNot(second));
      expect(store().albums.where((a) => a.name == '同名'), hasLength(2));
    });

    test('重命名持久化且空名拒绝', () async {
      final id = await store().createAlbum('旧名');
      await store().renameAlbum(id, ' 新名 ');
      expect(store().albumById(id)!.name, '新名');
      expect((readIndex()['albums'] as List).single['name'], '新名');
      await expectLater(
        store().renameAlbum(id, '   '),
        throwsA(isA<CoverAlbumException>()),
      );
    });

    test('删除相册：索引移除 + 目录递归清理', () async {
      final id = await store().createAlbum('待删');
      await importBytes(id, isDark: false, bytes: _png(r: 10));
      final dir = Directory('${rootPath()}${Platform.pathSeparator}$id');
      expect(dir.existsSync(), isTrue);
      await store().deleteAlbum(id);
      expect(store().albumById(id), isNull);
      expect(dir.existsSync(), isFalse);
      expect(readIndex()['albums'], isEmpty);
    });
  });

  group('图片导入', () {
    test('SHA-256 命名、同内容不同扩展名不重复写盘', () async {
      final id = await store().createAlbum('相册');
      final first = await importBytes(
        id,
        isDark: false,
        bytes: _png(r: 200),
        name: 'photo.PNG',
      );
      expect(first.failures, isEmpty);
      expect(first.imported, hasLength(1));
      final fileName = first.imported.single.fileName;
      expect(fileName, matches(RegExp(r'^[0-9a-f]{64}\.png$')));

      final second = await importBytes(
        id,
        isDark: false,
        bytes: _png(r: 200),
        name: 'same.jpeg',
      );
      expect(second.imported, isEmpty, reason: '同一内容已存在，不重复导入');
      final dir = Directory('${rootPath()}${Platform.pathSeparator}$id');
      expect(
        dir.listSync().whereType<File>(),
        hasLength(1),
        reason: '同一内容只保留一个文件',
      );
      expect(store().albumById(id)!.lightCount, 1);
      expect((readIndex()['albums'] as List).single['lightImages'], <String>[
        fileName,
      ]);
    });

    test('同一文件可同时用于日/夜；两侧都移除后才删文件与空目录', () async {
      final id = await store().createAlbum('相册');
      final bytes = _png(r: 50, g: 60);
      await importBytes(id, isDark: false, bytes: bytes);
      await importBytes(id, isDark: true, bytes: bytes);
      final album = store().albumById(id)!;
      expect(album.lightCount, 1);
      expect(album.darkCount, 1);
      expect(
        album.lightImages.single.fileName,
        album.darkImages.single.fileName,
      );
      final dir = Directory('${rootPath()}${Platform.pathSeparator}$id');
      expect(dir.listSync().whereType<File>(), hasLength(1));

      await store().removeImage(
        id,
        isDark: false,
        fileName: album.lightImages.single.fileName,
      );
      expect(dir.existsSync(), isTrue);
      expect(dir.listSync().whereType<File>(), hasLength(1));

      await store().removeImage(
        id,
        isDark: true,
        fileName: album.darkImages.single.fileName,
      );
      expect(store().albumById(id)!.lightCount, 0);
      expect(store().albumById(id)!.darkCount, 0);
      expect(dir.existsSync(), isFalse, reason: '相册目录为空时一并清理');
    });

    test('空/非图片/超限逐张拒绝，合法图仍导入', () async {
      final id = await store().createAlbum('相册');
      final result = await store().importImages(
        id,
        isDark: false,
        inputs: [
          CoverAlbumImageInput(displayName: 'empty.png', bytes: Uint8List(0)),
          CoverAlbumImageInput(
            displayName: 'broken.png',
            bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
          ),
          CoverAlbumImageInput(
            displayName: 'huge.png',
            bytes: Uint8List(CoverAlbumStore.maxBytes + 1),
          ),
          CoverAlbumImageInput(displayName: 'ok.png', bytes: _png(r: 1, g: 2)),
        ],
      );
      expect(result.imported, hasLength(1));
      expect(result.failures, hasLength(3));
      expect(
        result.failures.map((f) => f.message).join('\n'),
        allOf(contains('图片内容为空'), contains('不是可解码的图片'), contains('图片过大')),
      );
      expect(store().albumById(id)!.lightCount, 1);
    });

    test('原子写：无 .tmp 残留，索引可重新解析', () async {
      final id = await store().createAlbum('相册');
      await importBytes(id, isDark: false, bytes: _png(r: 3));
      final leftovers = rootDir()
          .listSync(recursive: true)
          .where((entity) => entity.path.contains('.tmp-'))
          .toList();
      expect(leftovers, isEmpty);
      expect(readIndex()['formatVersion'], CoverAlbumStore.formatVersion);
    });
  });

  group('索引健壮性', () {
    test('损坏索引按空相册处理，不抛出', () async {
      await rootDir().create(recursive: true);
      File(
        '${rootPath()}${Platform.pathSeparator}'
        '${CoverAlbumStore.indexFileName}',
      ).writeAsStringSync('{not-json');
      await store().ensureLoaded();
      expect(store().isLoaded, isTrue);
      expect(store().albums, isEmpty);
    });

    test('非法相册 ID / 穿越文件名被跳过，合法项保留', () async {
      await rootDir().create(recursive: true);
      final goodDir = Directory(
        '${rootPath()}${Platform.pathSeparator}good-album',
      );
      goodDir.createSync(recursive: true);
      final validName = 'legacy-cover.png';
      File(
        '${goodDir.path}${Platform.pathSeparator}$validName',
      ).writeAsBytesSync(_png(r: 9));
      File(
        '${rootPath()}${Platform.pathSeparator}'
        '${CoverAlbumStore.indexFileName}',
      ).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'formatVersion': 2,
          'albums': [
            {
              'id': '../evil',
              'name': 'evil',
              'lightImages': <String>['../../escape.png'],
              'darkImages': <String>[],
            },
            {
              'id': 'good-album',
              'name': 'Good',
              'lightImages': <String>['../escape.png', validName],
              'darkImages': <String>['..'],
            },
          ],
        }),
      );
      await store().ensureLoaded();
      expect(store().albums, hasLength(1));
      final album = store().albumById('good-album')!;
      expect(album.lightImages.map((i) => i.fileName), <String>[validName]);
      expect(album.darkImages, isEmpty);
    });

    test('v1 单列表 images 升级为 v2 日/夜同源并落盘', () async {
      await rootDir().create(recursive: true);
      final albumDir = Directory('${rootPath()}${Platform.pathSeparator}a1');
      albumDir.createSync(recursive: true);
      const name = 'old-cover.png';
      File(
        '${albumDir.path}${Platform.pathSeparator}$name',
      ).writeAsBytesSync(_png(r: 4));
      File(
        '${rootPath()}${Platform.pathSeparator}'
        '${CoverAlbumStore.indexFileName}',
      ).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'formatVersion': 1,
          'albums': [
            {
              'id': 'a1',
              'name': '旧相册',
              'images': <String>[name],
            },
          ],
        }),
      );
      await store().ensureLoaded();
      final album = store().albumById('a1')!;
      expect(album.lightCount, 1);
      expect(album.darkCount, 1);
      expect(readIndex()['formatVersion'], 2);
    });
  });

  group('旧偏好迁移', () {
    test('defaultCover/defaultCoverDark 逗号路径迁入 default-cover 且幂等', () async {
      final legacy = Directory('${temp.path}${Platform.pathSeparator}legacy');
      legacy.createSync(recursive: true);
      final day = File('${legacy.path}${Platform.pathSeparator}day.png')
        ..writeAsBytesSync(_png(r: 11));
      final night = File('${legacy.path}${Platform.pathSeparator}night.png')
        ..writeAsBytesSync(_png(r: 22));
      final missing = '${legacy.path}${Platform.pathSeparator}missing.png';
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.coverDefaultAlbumId: '${day.path},$missing',
        PrefKeys.coverDefaultAlbumIdDark: night.path,
      });

      await store().ensureLoaded();
      final migration = store().takePendingMigration()!;
      expect(migration.albumId, CoverAlbumStore.legacyAlbumId);
      expect(migration.clearDarkSelection, isTrue);
      final album = store().albumById(CoverAlbumStore.legacyAlbumId)!;
      expect(album.name, CoverAlbumStore.legacyAlbumName);
      expect(album.lightCount, 1);
      expect(album.darkCount, 1);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          PrefKeys.coverAlbumMigrated,
        ),
        isTrue,
      );

      // 幂等：再次加载不重复复制、不重复追加
      await store().reload();
      expect(store().takePendingMigration(), isNull);
      final again = store().albumById(CoverAlbumStore.legacyAlbumId)!;
      expect(again.lightCount, 1);
      expect(again.darkCount, 1);
    });

    test('defaultCover 为相册 ID 时不误判为路径', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.coverDefaultAlbumId: 'album-1234',
      });
      await store().ensureLoaded();
      expect(store().albums, isEmpty);
      expect(store().takePendingMigration(), isNull);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          PrefKeys.coverAlbumMigrated,
        ),
        isTrue,
      );
    });

    test('迁移后 Notifier 写入 defaultAlbumId 并清空旧夜间路径键', () async {
      final legacy = Directory('${temp.path}${Platform.pathSeparator}legacy');
      legacy.createSync(recursive: true);
      final day = File('${legacy.path}${Platform.pathSeparator}day.png')
        ..writeAsBytesSync(_png(r: 33));
      final night = File('${legacy.path}${Platform.pathSeparator}night.png')
        ..writeAsBytesSync(_png(r: 44));
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.coverDefaultAlbumId: day.path,
        PrefKeys.coverDefaultAlbumIdDark: night.path,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(coverSettingsProvider);
      await container.read(coverSettingsProvider.notifier).waitForLoad();

      expect(
        container.read(coverSettingsProvider).defaultAlbumId,
        CoverAlbumStore.legacyAlbumId,
      );
      expect(container.read(coverSettingsProvider).defaultAlbumIdDark, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PrefKeys.coverDefaultAlbumId),
        CoverAlbumStore.legacyAlbumId,
      );
      expect(prefs.getString(PrefKeys.coverDefaultAlbumIdDark), '');
    });

    test('指向不存在相册的 defaultAlbumId 回落内置封面并写回空值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.coverDefaultAlbumId: 'missing-album',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(coverSettingsProvider);
      await container.read(coverSettingsProvider.notifier).waitForLoad();

      expect(container.read(coverSettingsProvider).defaultAlbumId, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.coverDefaultAlbumId), '');
    });
  });

  group('种子与备份', () {
    test('书名种子稳定（Random(hashCode)）、空种子稳定、日/夜间独立', () async {
      expect(
        CoverAlbumStore.coverAlbumSeedIndex(null, 5),
        CoverAlbumStore.coverAlbumSeedIndex('', 5),
      );
      expect(
        CoverAlbumStore.coverAlbumSeedIndex(null, 5),
        inInclusiveRange(0, 4),
      );
      // 对齐参考版 Random(seed.hashCode).nextInt(n)：'a' hashCode=97
      expect(CoverAlbumStore.coverAlbumSeedIndex('a', 10), 9);
      expect(CoverAlbumStore.coverAlbumSeedIndex('a', 10), 9);

      final id = await store().createAlbum('相册');
      await importBytes(id, isDark: false, bytes: _png(r: 1, g: 1));
      await importBytes(id, isDark: false, bytes: _png(r: 2, g: 2));
      final album = store().albumById(id)!;
      expect(album.lightCount, 2);
      final expectedA =
          album.lightImages[CoverAlbumStore.coverAlbumSeedIndex('a', 2)].path;
      expect(
        store().imagePathForAlbum(id, isDark: false, seed: 'a'),
        expectedA,
      );
      expect(
        store().imagePathForAlbum(id, isDark: false, seed: 'a'),
        expectedA,
        reason: '同一书名每次取同一张',
      );
      expect(
        store().imagePathForAlbum(id, isDark: false, seed: ''),
        album.lightImages[CoverAlbumStore.coverAlbumSeedIndex('', 2)].path,
      );
      expect(
        store().imagePathForAlbum(id, isDark: true, seed: 'a'),
        isNull,
        reason: '夜间列表为空 → 回落内置封面',
      );
      expect(
        store().imagePathForAlbum('missing', isDark: false, seed: 'a'),
        isNull,
      );
    });

    test('中文 / emoji / 空种子稳定且落在范围内', () {
      for (final seed in <String?>['斗破苍穹', '📚📖', '', null, 'a']) {
        final first = CoverAlbumStore.coverAlbumSeedIndex(seed, 7);
        expect(first, inInclusiveRange(0, 6), reason: '$seed');
        expect(CoverAlbumStore.coverAlbumSeedIndex(seed, 7), first);
      }
    });

    test('备份排除 defaultCover/defaultCoverDark 与迁移标记', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.coverDefaultAlbumId: 'album-x',
        PrefKeys.coverDefaultAlbumIdDark: 'album-y',
        PrefKeys.coverAlbumMigrated: true,
        CoverSettings.keyShowShadow: true,
      });
      final backup = await RestoreIgnorePrefs.collectForBackup(
        <String, bool>{},
      );
      expect(backup.containsKey(PrefKeys.coverDefaultAlbumId), isFalse);
      expect(backup.containsKey(PrefKeys.coverDefaultAlbumIdDark), isFalse);
      expect(backup.containsKey(PrefKeys.coverAlbumMigrated), isFalse);
      expect(backup[CoverSettings.keyShowShadow], isTrue);
    });

    test('恢复备份不覆盖本机相册选择（alwaysIgnoreKeys）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.coverDefaultAlbumId: 'local-album',
      });
      await RestoreIgnorePrefs.applyFromBackup(<String, dynamic>{
        PrefKeys.coverDefaultAlbumId: 'backup-album',
      }, <String, bool>{});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.coverDefaultAlbumId), 'local-album');
    });
  });
}
