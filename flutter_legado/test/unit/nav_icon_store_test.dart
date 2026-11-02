// [复核 P2-5/P2-6 | 2026-11-02] 导航自定义图标存储单测
//
// 覆盖：32MB/空/坏图校验、流式 sha1 内容命名、原子写无 tmp 残留、重复去重、
// 相对 `nav_icons/<sha1>.<ext>` 标识与当前 Support 解析、旧绝对路径兼容、
// 跨容器/重装模拟、删除只允许自有目录、孤儿清理（保留引用/超龄 tmp 区分）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/nav_icon_store.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

String _hashLike(String ch) => List<String>.filled(40, ch).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legado_nav_icons_');
    originalSupportDir = NavIconStore.supportDir;
    NavIconStore.supportDir = () async => temp;
    NavIconStore.warmWith(temp);
  });

  tearDown(() async {
    NavIconStore.supportDir = originalSupportDir;
    NavIconStore.resetWarmCache();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Directory iconDir([Directory? root]) => Directory(
    '${(root ?? temp).path}${Platform.pathSeparator}${NavIconStore.subDir}',
  );

  Future<File> writeSource(String name, {List<int>? bytes}) async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}src');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes ?? _pngBytes);
    return file;
  }

  group('importBytes（SAF 字节流）', () {
    test('合法 PNG：返回相对 sha1 标识、字节一致、重复去重、无 tmp 残留', () async {
      final first = await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'picked.PNG',
      );
      expect(first, matches(RegExp(r'^nav_icons/[0-9a-f]{40}\.png$')));
      expect(NavIconStore.isUsableSync(first), isTrue);
      final resolved = NavIconStore.resolveSync(first);
      expect(resolved, isNot(first), reason: '相对标识应拼到当前 Support');
      expect(File(resolved).readAsBytesSync(), _pngBytes);

      final second = await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'another-name.png',
      );
      expect(second, first, reason: '内容相同应命中去重');
      final files = iconDir().listSync().whereType<File>().toList();
      expect(files.length, 1);
      expect(files.where((f) => f.path.contains('.tmp-')), isEmpty);
    });

    test('空字节/超 32MB/坏图均拒绝且不落盘', () async {
      await expectLater(
        NavIconStore.importBytes(Uint8List(0), originalName: 'empty.png'),
        throwsA(isA<FormatException>()),
      );

      await expectLater(
        NavIconStore.importBytes(
          Uint8List(NavIconStore.maxBytes + 1),
          originalName: 'big.png',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('32MB'),
          ),
        ),
      );

      await expectLater(
        NavIconStore.importBytes(
          Uint8List.fromList(const <int>[1, 2, 3, 4]),
          originalName: 'fake.png',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('不是可解码的图片'),
          ),
        ),
      );

      final dir = iconDir();
      expect(
        dir.existsSync() ? dir.listSync() : const <FileSystemEntity>[],
        isEmpty,
        reason: '校验失败不得写正式文件或 tmp',
      );
    });

    test('未知扩展名回落 jpg；大小写与路径无关', () async {
      final stored = await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'picked.HEIC',
      );
      expect(stored, matches(RegExp(r'^nav_icons/[0-9a-f]{40}\.jpg$')));
    });
  });

  group('importFromPath（iOS/桌面/测试文件路径）', () {
    test('流式 sha1 内容命名、返回相对标识、重复去重', () async {
      final source = await writeSource('photo.PNG');
      final first = await NavIconStore.importFromPath(source.path);
      expect(first, matches(RegExp(r'^nav_icons/[0-9a-f]{40}\.png$')));
      expect(NavIconStore.isUsableSync(first), isTrue);
      expect(
        File(NavIconStore.resolveSync(first)).readAsBytesSync(),
        _pngBytes,
      );

      final second = await NavIconStore.importFromPath(source.path);
      expect(second, first);
      final files = iconDir().listSync().whereType<File>().toList();
      expect(files.length, 1);
      expect(files.where((f) => f.path.contains('.tmp-')), isEmpty);
    });

    test('源文件已在目标目录内：幂等返回相对标识，不重复拷贝', () async {
      final stored = await NavIconStore.importFromPath(
        (await writeSource('idem.png')).path,
      );
      final storedPath = NavIconStore.resolveSync(stored);
      final again = await NavIconStore.importFromPath(storedPath);
      expect(again, stored);
    });

    test('空文件/超限/坏图拒绝', () async {
      final empty = await writeSource('empty.png', bytes: const []);
      await expectLater(
        NavIconStore.importFromPath(empty.path),
        throwsA(isA<FormatException>()),
      );

      final big = await writeSource(
        'big.png',
        bytes: List<int>.filled(NavIconStore.maxBytes + 1, 0),
      );
      await expectLater(
        NavIconStore.importFromPath(big.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('32MB'),
          ),
        ),
      );

      final fake = await writeSource('fake.png', bytes: const [1, 2, 3, 4]);
      await expectLater(
        NavIconStore.importFromPath(fake.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('不是可解码的图片'),
          ),
        ),
      );
    });
  });

  group('相对标识 / 旧绝对路径兼容', () {
    test('跨容器：相对标识按新 Support 解析，旧绝对路径仍可读', () async {
      final stored = await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'home.png',
      );
      final oldResolved = NavIconStore.resolveSync(stored);
      expect(NavIconStore.isUsableSync(stored), isTrue);

      final newContainer = await Directory.systemTemp.createTemp(
        'legado_nav_new_',
      );
      addTearDown(() async {
        if (await newContainer.exists()) {
          await newContainer.delete(recursive: true);
        }
      });
      NavIconStore.supportDir = () async => newContainer;
      NavIconStore.warmWith(newContainer);

      // 新容器没有该文件 → 相对标识不可用（回退内置图标）
      expect(NavIconStore.isUsableSync(stored), isFalse);
      expect(
        NavIconStore.resolveSync(stored).startsWith(newContainer.path),
        isTrue,
      );

      // 模拟重装/换容器后文件被迁移到新 Support：相对标识立即恢复
      final migrated = File(
        '${newContainer.path}${Platform.pathSeparator}'
        '${stored.replaceAll('/', Platform.pathSeparator)}',
      );
      await migrated.parent.create(recursive: true);
      await File(oldResolved).copy(migrated.path);
      expect(NavIconStore.isUsableSync(stored), isTrue);

      // 旧绝对路径（旧容器）仍按原样可读
      expect(NavIconStore.isUsableSync(oldResolved), isTrue);
    });

    test('未预热时相对标识不可用（不误读工作目录）', () {
      NavIconStore.resetWarmCache();
      expect(NavIconStore.resolveSync('nav_icons/${_hashLike('a')}.png'), '');
      expect(
        NavIconStore.isUsableSync('nav_icons/${_hashLike('a')}.png'),
        isFalse,
      );
    });

    test('非法相对标识/路径穿越不可解析', () {
      expect(NavIconStore.resolveSync('other/abc.png'), '');
      expect(
        NavIconStore.resolveSync('nav_icons/../${_hashLike('a')}.png'),
        '',
      );
    });
  });

  group('deleteIfUnused', () {
    test('未引用：删除自有文件；被引用（相对或绝对）不删', () async {
      final stored = await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'home.png',
      );
      final resolved = NavIconStore.resolveSync(stored);

      expect(
        await NavIconStore.deleteIfUnused(stored, keep: [stored]),
        isFalse,
      );
      expect(File(resolved).existsSync(), isTrue);

      expect(
        await NavIconStore.deleteIfUnused(stored, keep: [resolved]),
        isFalse,
        reason: 'keep 混用绝对路径也应视为仍被引用',
      );
      expect(File(resolved).existsSync(), isTrue);

      expect(await NavIconStore.deleteIfUnused(stored, keep: const []), isTrue);
      expect(File(resolved).existsSync(), isFalse);
      expect(
        await NavIconStore.deleteIfUnused(stored, keep: const []),
        isFalse,
      );
    });

    test('旧绝对路径位于当前 nav_icons 内可删；外部路径绝不删', () async {
      final stored = await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'rss.png',
      );
      final resolved = NavIconStore.resolveSync(stored);
      expect(
        await NavIconStore.deleteIfUnused(resolved, keep: const []),
        isTrue,
      );

      final outside = await writeSource('outside.png');
      expect(
        await NavIconStore.deleteIfUnused(outside.path, keep: const []),
        isFalse,
      );
      expect(outside.existsSync(), isTrue);
    });
  });

  group('cleanupOrphansSync', () {
    test('保留引用；删除未引用自有文件与超龄 tmp；保留新 tmp/非自有文件', () async {
      final kept = await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'kept.png',
      );
      final orphan = File(
        '${iconDir().path}${Platform.pathSeparator}${_hashLike('b')}.png',
      );
      await orphan.writeAsBytes(_pngBytes);

      final oldTmp = File(
        '${iconDir().path}${Platform.pathSeparator}.${_hashLike('c')}.png.tmp-1',
      );
      await oldTmp.writeAsBytes(_pngBytes);
      oldTmp.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );

      final freshTmp = File(
        '${iconDir().path}${Platform.pathSeparator}.${_hashLike('d')}.png.tmp-2',
      );
      await freshTmp.writeAsBytes(_pngBytes);

      final foreign = File(
        '${iconDir().path}${Platform.pathSeparator}keep-me.txt',
      );
      await foreign.writeAsBytes(const [1]);

      final removed = NavIconStore.cleanupOrphansSync(keep: [kept]);
      expect(removed, 2);
      expect(NavIconStore.isUsableSync(kept), isTrue);
      expect(orphan.existsSync(), isFalse);
      expect(oldTmp.existsSync(), isFalse);
      expect(freshTmp.existsSync(), isTrue);
      expect(foreign.existsSync(), isTrue);
    });

    test('deleteAll 清空 nav_icons 目录', () async {
      await NavIconStore.importBytes(
        Uint8List.fromList(_pngBytes),
        originalName: 'home.png',
      );
      expect(iconDir().existsSync(), isTrue);
      await NavIconStore.deleteAll();
      expect(iconDir().existsSync(), isFalse);
    });
  });
}
