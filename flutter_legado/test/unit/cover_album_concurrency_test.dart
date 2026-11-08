// 封面相册并发/内存一致性测试（设置批6b-2 审查回修 P2-1/P2-2/P3）
//
// 覆盖：变更串行（导入中删除等待、A/B 导入顺序）、await 后按 id 重定位、
// 目录被外部删除后导入重建、索引落盘失败不先更新内存/回收新文件、
// reload 等待在途导入、哈希/写盘走后台执行器、FLUTTER_TEST 跳过说明。
import 'dart:async';
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

Uint8List _png({int r = 0}) {
  final image = img.Image(width: 2, height: 2);
  image.setPixelRgb(0, 0, r, 0, 0);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  String rootPath() => '${temp.path}${Platform.pathSeparator}cover_albums';

  File indexFile() => File(
    '${rootPath()}${Platform.pathSeparator}'
    '${CoverAlbumStore.indexFileName}',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CoverAlbumStore.resetForTest();
    temp = await Directory.systemTemp.createTemp('legado_cover_concurrency_');
    CoverAlbumStore.supportDirOverride = () async => temp;
    CoverAlbumStore.decodeOverride = (_) async => true;
    CoverAlbumStore.isolateOverride = <T>(T Function() action) async =>
        action();
  });

  tearDown(() async {
    CoverAlbumStore.resetForTest();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  CoverAlbumStore store() => CoverAlbumStore.instance;

  Future<String> newAlbum([String name = '相册']) => store().createAlbum(name);

  test('导入等待解码期间删除被串行化，最终索引一致且无 RangeError', () async {
    final id = await newAlbum();
    final gate = Completer<bool>();
    CoverAlbumStore.decodeOverride = (_) => gate.future;
    final importFuture = store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 7))],
    );
    await Future<void>.delayed(Duration.zero);
    final deleteFuture = store().deleteAlbum(id);
    await Future<void>.delayed(Duration.zero);
    // 导入持有队列，删除必须等待：相册仍在
    expect(store().albumById(id), isNotNull);
    gate.complete(true);
    await importFuture;
    await deleteFuture;
    expect(store().albumById(id), isNull);
    final index = jsonDecode(indexFile().readAsStringSync()) as Map;
    expect(index['albums'], isEmpty);
  });

  test('两个导入按调用顺序串行，均落盘且计数正确', () async {
    final id = await newAlbum();
    final gates = <Completer<bool>>[];
    CoverAlbumStore.decodeOverride = (_) {
      final gate = Completer<bool>();
      gates.add(gate);
      return gate.future;
    };
    final first = store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 11))],
    );
    final second = store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'b.png', bytes: _png(r: 12))],
    );
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(1), reason: '第二个导入必须等第一个完成');
    gates.first.complete(true);
    await Future<void>.delayed(Duration.zero);
    gates.last.complete(true);
    await first;
    await second;
    expect(store().albumById(id)!.lightCount, 2);
    final index = jsonDecode(indexFile().readAsStringSync()) as Map;
    expect((index['albums'] as List).single['lightImages'], hasLength(2));
  });

  test('相册目录被外部删除后导入会重建目录并成功', () async {
    final id = await newAlbum();
    final dir = Directory('${rootPath()}${Platform.pathSeparator}$id');
    dir.deleteSync(recursive: true);
    final result = await store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 21))],
    );
    expect(result.imported, hasLength(1));
    expect(dir.existsSync(), isTrue);
    expect(store().albumById(id)!.lightCount, 1);
  });

  test('索引落盘失败：内存保持旧列表并回收新文件', () async {
    final id = await newAlbum();
    final dir = Directory('${rootPath()}${Platform.pathSeparator}$id');
    CoverAlbumStore.failNextIndexWrite = true;
    await expectLater(
      store().importImages(
        id,
        isDark: false,
        inputs: [
          CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 31)),
        ],
      ),
      throwsA(isA<CoverAlbumException>()),
    );
    expect(store().albumById(id)!.lightCount, 0, reason: '落盘失败不先更新内存');
    expect(dir.existsSync(), isTrue);
    expect(dir.listSync().whereType<File>(), isEmpty, reason: '本次复制的孤儿文件应回收');
  });

  test('reload 等待在途导入完成，不把旧结果写回', () async {
    final id = await newAlbum();
    final gate = Completer<bool>();
    CoverAlbumStore.decodeOverride = (_) => gate.future;
    final importFuture = store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 41))],
    );
    await Future<void>.delayed(Duration.zero);
    var reloadDone = false;
    final reloadFuture = store().reload().then((_) => reloadDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(reloadDone, isFalse, reason: 'reload 排在导入之后');
    gate.complete(true);
    await importFuture;
    await reloadFuture;
    expect(reloadDone, isTrue);
    expect(store().isLoaded, isTrue);
    expect(store().albumById(id)!.lightCount, 1);
  });

  test('索引读取/哈希/写盘走后台执行器（可注入记录调用）', () async {
    var calls = 0;
    CoverAlbumStore.isolateOverride = <T>(T Function() action) async {
      calls++;
      return action();
    };
    await store().ensureLoaded();
    expect(calls, greaterThanOrEqualTo(1), reason: '索引读取在后台执行器内');
    final id = await newAlbum();
    calls = 0;
    await store().importImages(
      id,
      isDark: false,
      inputs: [CoverAlbumImageInput(displayName: 'a.png', bytes: _png(r: 51))],
    );
    expect(calls, greaterThanOrEqualTo(2), reason: '哈希与写盘各一次后台任务');
  });

  test('FLUTTER_TEST 未注入目录时跳过加载（仅测试环境）', () async {
    CoverAlbumStore.resetForTest();
    await store().ensureLoaded();
    expect(store().isLoaded, isTrue);
    expect(store().hasRoot, isFalse);
    expect(store().albums, isEmpty);
    // 恢复 seam 供 tearDown 清理（temp 未使用）
    CoverAlbumStore.supportDirOverride = () async => temp;
  });

  test('旧 defaultCoverDark 路径缺失时仍清空该键（形态判断）', () async {
    final legacy = Directory('${temp.path}${Platform.pathSeparator}legacy');
    legacy.createSync(recursive: true);
    final day = File('${legacy.path}${Platform.pathSeparator}day.png')
      ..writeAsBytesSync(_png(r: 61));
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.coverDefaultAlbumId: day.path,
      PrefKeys.coverDefaultAlbumIdDark:
          '${legacy.path}${Platform.pathSeparator}missing.png',
    });
    await store().ensureLoaded();
    final migration = store().takePendingMigration()!;
    expect(migration.clearDarkSelection, isTrue);
    expect(store().albumById(CoverAlbumStore.legacyAlbumId)!.lightCount, 1);
    expect(store().albumById(CoverAlbumStore.legacyAlbumId)!.darkCount, 0);
  });

  test('日间有效 + 夜间缺失：迁移标记清除夜间路径并写空键', () async {
    final legacy = Directory('${temp.path}${Platform.pathSeparator}legacy');
    legacy.createSync(recursive: true);
    final day = File('${legacy.path}${Platform.pathSeparator}day.png')
      ..writeAsBytesSync(_png(r: 62));
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.coverDefaultAlbumId: day.path,
      PrefKeys.coverDefaultAlbumIdDark:
          '${legacy.path}${Platform.pathSeparator}missing.png',
    });
    coverSettingsListenable.value = CoverSettings.defaults;
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
    expect(prefs.getString(PrefKeys.coverDefaultAlbumIdDark), '');
  });

  test('启动清理索引落盘中断残留 tmp', () async {
    final root = Directory(rootPath());
    root.createSync(recursive: true);
    final stale = File(
      '${root.path}${Platform.pathSeparator}.'
      '${CoverAlbumStore.indexFileName}.tmp-123',
    );
    stale.writeAsStringSync('{}');
    await store().ensureLoaded();
    expect(stale.existsSync(), isFalse);
  });
}
