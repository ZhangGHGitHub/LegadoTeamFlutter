// [设置批2b-1a | 2026-11-01] 容器背景图存储单测 — 全栈工程师
//
// 覆盖：内容哈希命名/去重、相对 Support 标识解析、绝对路径透传、
// 文件缺失回落（isUsableSync=false）、清除只删自有文件（外部路径不动）、
// 非法槽位拒绝。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/theme_background_image_store.dart';

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

  Future<File> writeSource(String name, {int size = 8}) async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}src');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(List<int>.filled(size, 7));
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
