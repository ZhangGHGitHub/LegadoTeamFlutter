// 封面磁盘缓存探测单测（设置批6b-1 审查 R-P2-1）
//
// 覆盖：有效（未过期 + 文件存在）→ 命中；过期 validTill → 未命中；
// 文件被删除 → 未命中；loader 返回 null/抛错 → 未命中。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/cover_disk_cache.dart';

void main() {
  late Directory tempDir;
  late File file;

  setUp(() async {
    CoverDiskCache.reset();
    tempDir = await Directory.systemTemp.createTemp('cover_disk_cache_test');
    file = File('${tempDir.path}/cover.png')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() async {
    CoverDiskCache.reset();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('有效缓存（未过期 + 文件存在）返回文件', () async {
    CoverDiskCache.debugLoader = (_) async => CoverDiskCacheEntry(
      file: file,
      validTill: DateTime.now().add(const Duration(hours: 1)),
    );
    final result = await CoverDiskCache.validFile('https://cover.test/a.jpg');
    expect(result?.path, file.path);
  });

  test('过期 validTill 按未命中处理（避免跳过仅 WiFi 后重新下载）', () async {
    CoverDiskCache.debugLoader = (_) async => CoverDiskCacheEntry(
      file: file,
      validTill: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(await CoverDiskCache.validFile('https://cover.test/a.jpg'), isNull);
  });

  test('缓存文件被删除按未命中处理', () async {
    file.deleteSync();
    CoverDiskCache.debugLoader = (_) async => CoverDiskCacheEntry(
      file: file,
      validTill: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(await CoverDiskCache.validFile('https://cover.test/a.jpg'), isNull);
  });

  test('loader 返回 null / 抛错均按未命中处理', () async {
    CoverDiskCache.debugLoader = (_) async => null;
    expect(await CoverDiskCache.validFile('https://cover.test/a.jpg'), isNull);

    CoverDiskCache.debugLoader = (_) async {
      throw const FileSystemException('cache error');
    };
    expect(await CoverDiskCache.validFile('https://cover.test/a.jpg'), isNull);
  });
}
