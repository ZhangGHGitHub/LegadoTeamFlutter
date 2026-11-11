// 系统临时目录启动清扫单测
//
// 钉住批10/批11 遗留项：
// - 仅清理 `legado_webdav_only_*` / `legado_webdav_restore_*` 目录；
// - 超过 1 小时未修改的目录被删除，新建目录保留（避免误删进行中的备份/恢复）；
// - 删除失败只记日志、不抛错，目录保留待下次启动重试。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/temp_dir_cleaner.dart';

void main() {
  late Directory tempBase;

  setUp(() {
    tempBase = Directory.systemTemp.createTempSync('legado_temp_cleaner_test_');
  });

  tearDown(() {
    try {
      if (tempBase.existsSync()) tempBase.deleteSync(recursive: true);
    } catch (_) {
      // Windows 文件句柄延迟释放不影响断言
    }
  });

  String sep() => Platform.pathSeparator;

  Directory createDir(String name, {String? fileName}) {
    final dir = Directory('${tempBase.path}${sep()}$name')
      ..createSync(recursive: true);
    if (fileName != null) {
      File('${dir.path}${sep()}$fileName').writeAsStringSync('{}');
    }
    return dir;
  }

  test('超过 1 小时未修改的备份/恢复临时目录被删除，其它文件/目录保留', () async {
    final onlyDir = createDir(
      'legado_webdav_only_100',
      fileName: 'legado_backup_100.json',
    );
    final restoreDir = createDir(
      'legado_webdav_restore_200',
      fileName: 'backup_x.zip',
    );
    final unrelated = createDir('other_app_300');
    final samePrefixFile = File(
      '${tempBase.path}${sep()}legado_webdav_only_not_a_dir',
    )..writeAsStringSync('x');

    final deleted = await TempDirCleaner(
      tempDirProvider: () => tempBase,
      // 注入未来时间：刚创建的目录也被判定为「1 小时前修改」
      now: () => DateTime.now().add(const Duration(hours: 2)),
    ).sweep();

    expect(deleted, 2);
    expect(onlyDir.existsSync(), isFalse);
    expect(restoreDir.existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue, reason: '非本服务前缀不得删除');
    expect(samePrefixFile.existsSync(), isTrue, reason: '同前缀普通文件不属于清扫范围');
  });

  test('新建（未超过 1 小时）目录保留，交给创建方 finally 清理', () async {
    final freshOnly = createDir('legado_webdav_only_fresh');
    final freshRestore = createDir('legado_webdav_restore_fresh');

    final deleted = await TempDirCleaner(
      tempDirProvider: () => tempBase,
    ).sweep();

    expect(deleted, 0);
    expect(freshOnly.existsSync(), isTrue);
    expect(freshRestore.existsSync(), isTrue);
  });

  test('时间边界：恰好 maxAge 保留，maxAge+1ms 删除', () async {
    final boundary = createDir('legado_webdav_only_boundary');
    final base = DateTime(2026, 1, 1, 12);

    // 恰好 1 小时：`current.difference(modified) <= maxAge` → 保留
    final kept = await TempDirCleaner(
      tempDirProvider: () => tempBase,
      now: () => base,
      modifiedTimeProvider: (_) async =>
          base.subtract(const Duration(hours: 1)),
    ).sweep();
    expect(kept, 0);
    expect(boundary.existsSync(), isTrue);

    // 超过 1 毫秒：严格大于 maxAge → 删除
    final deleted = await TempDirCleaner(
      tempDirProvider: () => tempBase,
      now: () => base,
      modifiedTimeProvider: (_) async =>
          base.subtract(const Duration(hours: 1, milliseconds: 1)),
    ).sweep();
    expect(deleted, 1);
    expect(boundary.existsSync(), isFalse);
  });

  test('目录 mtime 不随文件内容更新：取最新子项 mtime 避免长写入误删', () async {
    final longWrite = createDir(
      'legado_webdav_only_long_write',
      fileName: 'legado_backup_100.json',
    );
    final child = File('${longWrite.path}${sep()}legado_backup_100.json');
    // 子项 mtime 设为未来，目录自身 mtime 仍是创建时刻；最近活动时间必须
    // 取子项的较大值，否则长任务会被误判为超过 1 小时未修改。
    final childTime = DateTime.now().add(const Duration(minutes: 30));
    await child.setLastModified(childTime);

    final actual = await child.lastModified();
    final latest = await TempDirCleaner.latestModifiedForTest(longWrite);
    expect(
      latest.millisecondsSinceEpoch,
      actual.millisecondsSinceEpoch,
      reason: '最新直接子项 mtime 晚于目录 mtime 时必须采用子项时间',
    );
    expect(latest.isAfter(DateTime.now()), isTrue);
  });

  test('删除失败只记日志、不抛错，目录保留待下次启动重试', () async {
    final stuck = createDir('legado_webdav_only_stuck');

    final cleaner = TempDirCleaner(
      tempDirProvider: () => tempBase,
      now: () => DateTime.now().add(const Duration(hours: 2)),
      deleteDir: (_) async => throw const FileSystemException('目录被占用'),
    );

    expect(await cleaner.sweep(), 0);
    expect(stuck.existsSync(), isTrue);
  });

  test('临时目录不存在时安全返回 0', () async {
    final missing = Directory('${tempBase.path}${sep()}missing');
    expect(await TempDirCleaner(tempDirProvider: () => missing).sweep(), 0);
  });
}
