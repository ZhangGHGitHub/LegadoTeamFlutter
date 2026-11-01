// [设置批2b-1a | 2026-11-01] 容器背景图存储单测 — 全栈工程师
//
// 覆盖：内容哈希命名/去重、相对 Support 标识解析、绝对路径透传、
// 文件缺失回落（isUsableSync=false）、清除只删自有文件（外部路径不动）、
// 非法槽位拒绝、存前试解码、.9.png 保留、孤儿清理。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:flutter_legado/src/services/theme_background_image_store.dart';

/// 1x1 透明 PNG（真实可解码）
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

/// 32 位十六进制样式名字（配合自有文件命名规则）
String _hashLike(String ch) => List<String>.filled(32, ch).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legado_theme_bg_');
    originalSupportDir = ThemeBackgroundImageStore.supportDir;
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
  });

  tearDown(() async {
    ThemeBackgroundImageStore.supportDir = originalSupportDir;
    ThemeBackgroundImageStore.resetWarmCache();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<File> writeSource(String name, {List<int>? bytes}) async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}src');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes ?? _pngBytes);
    return file;
  }

  test('复制到主题目录并返回内容哈希相对标识', () async {
    final source = await writeSource('photo.PNG');
    final stored = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_light',
    );

    expect(
      stored,
      matches(RegExp(r'^theme_backgrounds/large_light/[0-9a-f]{32}\.png$')),
    );
    final resolved = ThemeBackgroundImageStore.resolveSync(stored);
    expect(resolved, startsWith(temp.absolute.path));
    expect(File(resolved).existsSync(), isTrue);
    expect(ThemeBackgroundImageStore.isUsableSync(stored), isTrue);
  });

  test('同一内容重复选择去重（同标识、单文件、不重写）', () async {
    final source = await writeSource('a.jpg');
    final first = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_dark',
    );
    final second = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_dark',
    );

    expect(second, first);
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}theme_backgrounds'
      '${Platform.pathSeparator}large_dark',
    );
    expect(dir.listSync().whereType<File>().length, 1);
  });

  test('已位于目标槽位的文件幂等返回相对标识（不自拷贝）', () async {
    final source = await writeSource('seed.png');
    final stored = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_light',
    );
    final resolved = ThemeBackgroundImageStore.resolveSync(stored);

    expect(
      await ThemeBackgroundImageStore.store(resolved, slot: 'large_light'),
      stored,
    );
  });

  test('绝对路径透传；文件存在时可用', () async {
    final source = await writeSource('legacy.png');
    expect(
      ThemeBackgroundImageStore.resolveSync(source.path),
      source.absolute.path,
    );
    expect(ThemeBackgroundImageStore.isUsableSync(source.path), isTrue);
  });

  test('缺失文件回落：isUsableSync=false，resolveSync 不抛错', () {
    const missing = 'theme_backgrounds/large_light/not-exist.png';
    expect(ThemeBackgroundImageStore.resolveSync(missing), isNotEmpty);
    expect(ThemeBackgroundImageStore.isUsableSync(missing), isFalse);
    expect(ThemeBackgroundImageStore.isUsableSync(''), isFalse);
    expect(ThemeBackgroundImageStore.isUsableSync('/no/such/file.png'), isFalse);
  });

  test('deleteOwned 只删自有文件；外部绝对路径不动', () async {
    final source = await writeSource('owned.png');
    final stored = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_light',
    );
    final resolved = ThemeBackgroundImageStore.resolveSync(stored);

    expect(await ThemeBackgroundImageStore.deleteOwned(stored), isTrue);
    expect(File(resolved).existsSync(), isFalse);
    // 源文件在临时目录内、但不在 theme_backgrounds 下 → 不删除
    expect(await ThemeBackgroundImageStore.deleteOwned(source.path), isFalse);
    expect(source.existsSync(), isTrue);
    // 重复清理/空值安全
    expect(await ThemeBackgroundImageStore.deleteOwned(stored), isFalse);
    expect(await ThemeBackgroundImageStore.deleteOwned(''), isFalse);
  });

  test('非法槽位拒绝；源文件不存在抛错', () async {
    final source = await writeSource('bad.png');
    expect(
      () => ThemeBackgroundImageStore.store(source.path, slot: '../evil'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => ThemeBackgroundImageStore.store(
        '${temp.path}${Platform.pathSeparator}missing.png',
        slot: 'large_light',
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('扩展名规范化：未知扩展名回落 jpg', () async {
    final source = await writeSource('blob.unknown');
    final stored = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_light',
    );
    expect(stored, endsWith('.jpg'));
  });

  test('含 .. 段的备份路径按不可用回落，且不会被删除（防穿越）', () async {
    final outside = File('${temp.path}${Platform.pathSeparator}outside.png');
    await outside.writeAsBytes(List<int>.filled(8, 3));
    const traversal = 'theme_backgrounds/../outside.png';

    expect(ThemeBackgroundImageStore.isUsableSync(traversal), isFalse);
    expect(await ThemeBackgroundImageStore.deleteOwned(traversal), isFalse);
    expect(outside.existsSync(), isTrue);
  });

  test('文件为空时拒绝（FormatException）', () async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}src');
    await dir.create(recursive: true);
    final empty = File('${dir.path}${Platform.pathSeparator}empty.png');
    await empty.writeAsBytes(const <int>[]);
    expect(
      () => ThemeBackgroundImageStore.store(empty.path, slot: 'large_light'),
      throwsA(isA<FormatException>()),
    );
  });

  test('非图片/HEIC 等不可解码内容存前拒绝（FormatException）', () async {
    final source = await writeSource(
      'fake.png',
      bytes: utf8.encode('this is not an image'),
    );
    expect(
      () => ThemeBackgroundImageStore.store(source.path, slot: 'large_light'),
      throwsA(isA<FormatException>()),
    );
    // 不产生正式文件/残留 tmp
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}theme_backgrounds'
      '${Platform.pathSeparator}large_light',
    );
    if (dir.existsSync()) {
      expect(dir.listSync().whereType<File>(), isEmpty);
    }
  });

  test('截断 PNG（50/60 字节）存前拒绝（getNextFrame 校验）', () async {
    // 1x1 样例的 IDAT 极短，截到 50/60 字节仍可能解出完整像素（仅缺 IEND），
    // 无法覆盖 getNextFrame 分支；用 64x64 PNG 让截断落在 IDAT 数据流中。
    final bigPng = img.encodePng(img.Image(width: 64, height: 64));
    expect(bigPng.length, greaterThan(100));

    // 完整图可正常存储（证明样本有效，排除"样本本身坏"）
    final okSource = await writeSource('big_ok.png', bytes: bigPng);
    final okStored = await ThemeBackgroundImageStore.store(
      okSource.path,
      slot: 'large_light',
    );
    expect(ThemeBackgroundImageStore.isUsableSync(okStored), isTrue);

    for (final length in <int>[50, 60]) {
      final source = await writeSource(
        'truncated_$length.png',
        bytes: bigPng.sublist(0, length),
      );
      expect(
        () => ThemeBackgroundImageStore.store(
          source.path,
          slot: 'large_dark',
        ),
        throwsA(isA<FormatException>()),
        reason: '仅解析头部成功的截断 PNG 必须在解帧阶段被拒绝',
      );
    }
  });

  test('.9.png 保留双扩展名（供 2b-1b 九宫格迁移识别）', () async {
    final source = await writeSource('frame.9.png');
    final stored = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_light',
    );
    expect(
      stored,
      matches(RegExp(r'^theme_backgrounds/large_light/[0-9a-f]{32}\.9\.png$')),
    );
    expect(ThemeBackgroundImageStore.isUsableSync(stored), isTrue);
  });

  test('cleanupOrphansSync 清理未引用自有图/超龄 tmp，保留新 tmp 与其他槽位',
      () async {
    final source = await writeSource('keep.png');
    final kept = await ThemeBackgroundImageStore.store(
      source.path,
      slot: 'large_light',
    );
    final sep = Platform.pathSeparator;
    final lightDir = Directory(
      '${temp.path}$sep${ThemeBackgroundImageStore.subDir}${sep}large_light',
    );
    final hashA = _hashLike('a');
    final orphan = File('${lightDir.path}$sep$hashA.png')
      ..writeAsBytesSync(const <int>[1, 2, 3]);
    // 超龄 tmp：应清理
    final oldTmp = File('${lightDir.path}$sep.${_hashLike('b')}.png.tmp-123')
      ..writeAsBytesSync(const <int>[1]);
    oldTmp.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    // 刚写入的 tmp（可能是一次进行中的原子写）：不得删除
    final freshTmp = File('${lightDir.path}$sep.${_hashLike('d')}.png.tmp-456')
      ..writeAsBytesSync(const <int>[1]);
    final notOurs = File('${lightDir.path}${sep}readme.txt')
      ..writeAsBytesSync(const <int>[1]);
    // 2b-1b 的项目图槽位：本批清理不扫描，必须保留
    final itemDir = Directory(
      '${temp.path}$sep${ThemeBackgroundImageStore.subDir}${sep}item_light',
    )..createSync(recursive: true);
    final itemFile = File('${itemDir.path}$sep${_hashLike('c')}.png')
      ..writeAsBytesSync(const <int>[1]);

    final removed = ThemeBackgroundImageStore.cleanupOrphansSync(keep: [kept]);

    expect(removed, 2, reason: '未引用正式图 + 超龄 tmp');
    expect(
      File(ThemeBackgroundImageStore.resolveSync(kept)).existsSync(),
      isTrue,
    );
    expect(orphan.existsSync(), isFalse);
    expect(oldTmp.existsSync(), isFalse);
    expect(freshTmp.existsSync(), isTrue, reason: '新 tmp 可能是进行中的写入');
    expect(notOurs.existsSync(), isTrue);
    expect(itemFile.existsSync(), isTrue,
        reason: 'item_* 槽位属 2b-1b，本批不清理');
  });

  // 便于其他用例复用：1x1 透明 PNG（widget 测试真实可解码）
  test('内置 1x1 PNG 样本有效', () {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
      '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
    );
    expect(bytes.length, greaterThan(8));
    expect(bytes.sublist(1, 4), utf8.encode('PNG'));
  });
}
