// [iOS 视角F C1] LocalBookStore 单测
//
// 验证「本地书持久化 + 相对可迁移标识」写/读侧语义：
// 1. store() 把源文件拷入 Documents/books/，返回相对 Documents 的标识（books/<name>）；
// 2. 幂等：源文件已在 books/ 内 → 返回相对标识，不做自拷贝；
// 3. 去重：同名冲突追加 _<n>，不覆盖既有文件；
// 4. resolveSync()：相对标识 → 当前 Documents 拼接；绝对 / Web URL 原样透传；
// 5. 源不存在时 store() 抛异常。
//
// documentsDir 为测试缝隙：覆盖为系统临时目录，避免触碰真实沙盒；
// 用例结束恢复原 seam，防止污染同进程其它测试。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/local_book_store.dart';

void main() {
  late Directory tempDocs;
  late Future<Directory> Function() originalSeam;
  final siblings = <Directory>[];

  // 建一个 docs 之外的「源」目录（模拟 file_picker 移动后的 tmp 文件位置）
  Directory srcDir(String suffix) {
    final d = Directory('${tempDocs.path}_$suffix');
    siblings.add(d);
    return d;
  }

  setUp(() {
    tempDocs = Directory.systemTemp.createTempSync('legado_lbs_test_');
    originalSeam = LocalBookStore.documentsDir;
    // 测试缝隙：把 Documents 目录指向临时目录
    LocalBookStore.documentsDir = () async => tempDocs;
    // 以占位目录预热基目录缓存；各用例 store 时会用真实 tempDocs 重新填充
    LocalBookStore.warmWith(tempDocs);
  });

  tearDown(() {
    LocalBookStore.documentsDir = originalSeam;
    for (final d in [...siblings, tempDocs]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
    siblings.clear();
  });

  group('LocalBookStore.store', () {
    test('拷贝源文件入 books/ 并返回相对标识', () async {
      final src = File('${srcDir('src').path}${Platform.pathSeparator}sample.txt');
      src.createSync(recursive: true);
      src.writeAsStringSync('第一章\n正文\n');

      final id = await LocalBookStore.store(src.path);
      expect(id, 'books/sample.txt');

      // 真实文件应落在 Documents/books/ 下（经 resolveSync 一致性校验）
      final resolved = LocalBookStore.resolveSync(id);
      expect(File(resolved).existsSync(), isTrue,
          reason: '持久文件应存在于 $resolved');
      expect(File(resolved).readAsStringSync(), contains('正文'));
    });

    test('幂等：源已在 books/ 内 → 返回相对标识，不做自拷贝', () async {
      final src = File('${srcDir('src').path}${Platform.pathSeparator}inner.epub');
      src.createSync(recursive: true);
      src.writeAsStringSync('EPUB');

      final first = await LocalBookStore.store(src.path); // books/inner.epub
      // 对「已持久化位置」再 store：应幂等返回同一标识
      final persisted = LocalBookStore.resolveSync(first);
      final again = await LocalBookStore.store(persisted);
      expect(again, first);
    });

    test('去重：同名冲突追加 _<n>，不覆盖既有文件', () async {
      final a = File('${srcDir('src').path}${Platform.pathSeparator}dup.txt');
      a.createSync(recursive: true);
      a.writeAsStringSync('A');
      final idA = await LocalBookStore.store(a.path);
      expect(idA, 'books/dup.txt');

      // 同名的第二份（内容不同）→ 追加 _1
      final b = File('${srcDir('src2').path}${Platform.pathSeparator}dup.txt');
      b.createSync(recursive: true);
      b.writeAsStringSync('B');
      final idB = await LocalBookStore.store(b.path);
      expect(idB, 'books/dup_1.txt');

      // 两份文件都应存在且内容各自保留
      expect(File(LocalBookStore.resolveSync(idA)).readAsStringSync(), 'A');
      expect(File(LocalBookStore.resolveSync(idB)).readAsStringSync(), 'B');
    });

    test('源不存在时 store 抛异常', () async {
      expect(
        LocalBookStore.store(
            '${srcDir('missing').path}${Platform.pathSeparator}nope.txt'),
        throwsA(anything),
      );
    });
  });

  group('LocalBookStore.resolveSync', () {
    test('相对标识 → 当前 Documents 拼接', () async {
      final src = File('${srcDir('src').path}${Platform.pathSeparator}r.txt');
      src.createSync(recursive: true);
      src.writeAsStringSync('x');
      await LocalBookStore.store(src.path);

      final resolved = LocalBookStore.resolveSync('books/r.txt');
      // 应指向刚写入的持久文件（resolveSync 与 store 的落盘位置一致）
      expect(File(resolved).existsSync(), isTrue,
          reason: 'resolveSync 应还原 store 写入的真实路径 $resolved');
      expect(resolved.endsWith('books${Platform.pathSeparator}r.txt'), isTrue);
    });

    test('绝对路径原样透传', () {
      final abs = Platform.isWindows ? r'C:\abs\book.epub' : '/abs/book.epub';
      expect(LocalBookStore.resolveSync(abs), abs);
    });

    test('Web URL 原样透传', () {
      expect(LocalBookStore.resolveSync('https://a.example.com/b.epub'),
          'https://a.example.com/b.epub');
    });
  });
}
