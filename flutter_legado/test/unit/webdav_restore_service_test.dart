// 批10：WebDavRestoreService 单测
//
// 覆盖：远端下载文件名/后缀保留、临时文件清理、JSON appPrefs 回填、
// 恢复忽略「本地书籍」临时过滤、zip 探测（需密码不恢复 / 免密恢复）、
// 恢复失败返回 failed、恢复/备份互斥 busy、下载失败清理临时目录。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/backup_inspect_info.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/services/webdav_restore_service.dart';

/// 可注入下载内容/探测/恢复结果的 BookApi 假实现
class _RestoreApi extends MockBookApi {
  List<int>? downloadBytes;
  String? downloadText;
  Object? downloadError;
  String? downloadedPath;

  BackupInspectInfo inspectResult = const BackupInspectInfo(
    format: BackupFormat.json,
    passwordRequired: false,
    passwordProtectedFiles: [],
  );
  Object? inspectError;
  int inspectCalls = 0;

  Object? restoreError;
  int restoreCalls = 0;
  String? restoredPath;
  String? restoredPassword;
  String? restoredContent;

  @override
  Future<void> webdavDownloadFile(
    String configJson,
    String path,
    String localFilePath,
  ) async {
    downloadedPath = localFilePath;
    final error = downloadError;
    if (error != null) throw error;
    final bytes = downloadBytes;
    if (bytes != null) {
      await File(localFilePath).writeAsBytes(bytes, flush: true);
    } else {
      await File(localFilePath).writeAsString(downloadText ?? '', flush: true);
    }
  }

  @override
  Future<BackupInspectInfo> backupInspect(String backupPath) async {
    inspectCalls++;
    final error = inspectError;
    if (error != null) throw error;
    return inspectResult;
  }

  @override
  Future<void> restore(String backupPath, {String? password}) async {
    restoreCalls++;
    restoredPath = backupPath;
    restoredPassword = password;
    try {
      restoredContent = await File(backupPath).readAsString();
    } catch (_) {
      // zip 等二进制容器不按文本读取
      restoredContent = null;
    }
    final error = restoreError;
    if (error != null) throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RestoreApi api;
  late SettingsService settings;
  late Directory tempBase;
  late int refreshCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalBackupService.resetForTest();
    api = _RestoreApi();
    settings = SettingsService();
    tempBase = Directory.systemTemp.createTempSync('legado_batch10_restore_');
    refreshCalls = 0;
  });

  tearDown(() {
    LocalBackupService.resetForTest();
    if (tempBase.existsSync()) tempBase.deleteSync(recursive: true);
  });

  WebDavRestoreService build() => WebDavRestoreService(
    api: api,
    settings: settings,
    tempDirProvider: () => tempBase,
  );

  group('restoreRemoteBackupExclusive', () {
    test('JSON 成功：保留下载名/后缀、应用 appPrefs、清理临时文件', () async {
      final remoteName = 'backup_20261110_120000_123.json';
      api.downloadText = jsonEncode({
        'appPrefs': {'testBatch10Pref': 'yes'},
        'books': [],
      });

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: remoteName,
        configJson: '{"url":"x"}',
        refresh: () async => refreshCalls++,
      );

      expect(result.status, WebDavRestoreStatus.success);
      expect(api.downloadedPath, endsWith(remoteName));
      expect(api.inspectCalls, 0, reason: '非 zip 不探测密码');
      expect(api.restoreCalls, 1);
      expect(api.restoredPath, endsWith(remoteName));
      expect(api.restoredPassword, isNull);
      expect(refreshCalls, 1);
      expect(
        (await SharedPreferences.getInstance()).getString('testBatch10Pref'),
        'yes',
      );
      expect(
        File(api.downloadedPath!).existsSync(),
        isFalse,
        reason: '临时下载文件必须在 finally 删除',
      );
      expect(tempBase.listSync(), isEmpty, reason: '独立临时子目录也应删除');
    });

    test('恢复忽略「本地书籍」：过滤临时 JSON 且保留 .json 后缀', () async {
      await settings.saveRestoreIgnoreConfig({'localBook': true});
      final remoteName = 'backup_20261110_120000_123.json';
      api.downloadText = jsonEncode({
        'books': [
          {'name': '本地书', 'origin': 'loc_book', 'type': 0},
          {'name': '在线书', 'origin': 'https://example.com', 'type': 0},
        ],
      });

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: remoteName,
        configJson: '{"url":"x"}',
      );

      expect(result.status, WebDavRestoreStatus.success);
      expect(api.restoredPath, endsWith('.json'));
      final restored = jsonDecode(api.restoredContent!) as Map;
      final books = restored['books'] as List;
      expect(books.length, 1);
      expect((books.single as Map)['name'], '在线书');
      expect(
        File(api.restoredPath!).existsSync(),
        isFalse,
        reason: '过滤用临时 JSON 必须清理',
      );
    });

    test('zip 需密码：不恢复，返回 passwordRequired', () async {
      final remoteName = 'backup_20261110_120000_123.zip';
      api.downloadBytes = [0x50, 0x4B, 0x03, 0x04, 0x00];
      api.inspectResult = const BackupInspectInfo(
        format: BackupFormat.zip,
        passwordRequired: true,
        passwordProtectedFiles: ['servers.json'],
      );

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: remoteName,
        configJson: '{"url":"x"}',
      );

      expect(result.status, WebDavRestoreStatus.passwordRequired);
      expect(
        result.inspect,
        same(api.inspectResult),
        reason: '密码框需要受保护文件清单，探测结果必须随结果返回',
      );
      expect(api.inspectCalls, 1);
      expect(api.restoreCalls, 0, reason: '需密码不得自动恢复');
      expect(File(api.downloadedPath!).existsSync(), isFalse);
      expect(refreshCalls, 0);
    });

    test('zip 需密码但调用方提供 password：正常恢复并透传密码', () async {
      final remoteName = 'backup_20261110_120000_123.zip';
      api.downloadBytes = [0x50, 0x4B, 0x03, 0x04, 0x00];
      api.inspectResult = const BackupInspectInfo(
        format: BackupFormat.zip,
        passwordRequired: true,
        passwordProtectedFiles: ['servers.json'],
      );

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: remoteName,
        configJson: '{"url":"x"}',
        password: '备份 密码',
      );

      expect(result.status, WebDavRestoreStatus.success);
      expect(api.inspectCalls, 1);
      expect(api.restoreCalls, 1);
      expect(api.restoredPath, endsWith('.zip'));
      expect(api.restoredPassword, '备份 密码');
      expect(File(api.downloadedPath!).existsSync(), isFalse);
      expect(tempBase.listSync(), isEmpty, reason: '临时目录仍须清理');
    });

    test('zip 免密：探测后正常恢复', () async {
      final remoteName = 'backup_20261110_120000_123.zip';
      api.downloadBytes = [0x50, 0x4B, 0x03, 0x04, 0x00];
      api.inspectResult = const BackupInspectInfo(
        format: BackupFormat.zip,
        passwordRequired: false,
        passwordProtectedFiles: [],
      );

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: remoteName,
        configJson: '{"url":"x"}',
      );

      expect(result.status, WebDavRestoreStatus.success);
      expect(api.inspectCalls, 1);
      expect(api.restoreCalls, 1);
      expect(api.restoredPath, endsWith('.zip'));
      expect(File(api.downloadedPath!).existsSync(), isFalse);
    });

    test('恢复失败：返回 failed 并携带原始异常，临时文件仍清理', () async {
      final remoteName = 'backup_20261110_120000_123.json';
      api.downloadText = '{"appPrefs":{}}';
      final boom = Exception('restore boom');
      api.restoreError = boom;

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: remoteName,
        configJson: '{"url":"x"}',
        refresh: () async => refreshCalls++,
      );

      expect(result.status, WebDavRestoreStatus.failed);
      expect(result.error, same(boom));
      expect(refreshCalls, 0, reason: '失败不得触发成功刷新');
      expect(File(api.downloadedPath!).existsSync(), isFalse);
      expect(tempBase.listSync(), isEmpty);
    });

    test('恢复成功但 refresh 抛异常：结果仍为 success', () async {
      final remoteName = 'backup_20261110_120000_123.json';
      api.downloadText = '{"appPrefs":{}}';

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: remoteName,
        configJson: '{"url":"x"}',
        refresh: () async => throw Exception('refresh boom'),
      );

      expect(
        result.status,
        WebDavRestoreStatus.success,
        reason: 'refresh 是恢复后的 UI 重读，失败不得改写恢复结果',
      );
      expect(api.restoreCalls, 1);
      expect(File(api.downloadedPath!).existsSync(), isFalse);
    });

    test('远端名含路径分隔符或 ..：拒绝下载', () async {
      for (final remoteName in [
        '../evil.json',
        'backup_a\\b.json',
        'backup_..json',
      ]) {
        final result = await build().restoreRemoteBackupExclusive(
          remoteName: remoteName,
          configJson: '{"url":"x"}',
        );
        expect(result.status, WebDavRestoreStatus.failed);
        expect(result.error, isA<FormatException>());
      }
      expect(api.downloadedPath, isNull, reason: '非法名不得发起下载');
    });

    test('下载失败：failed 且清理刚创建的临时目录', () async {
      final boom = Exception('download boom');
      api.downloadError = boom;

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: 'backup_20261110_120000_123.json',
        configJson: '{"url":"x"}',
      );

      expect(result.status, WebDavRestoreStatus.failed);
      expect(result.error, same(boom));
      expect(api.downloadedPath, isNotNull);
      expect(
        File(api.downloadedPath!).parent.existsSync(),
        isFalse,
        reason: '下载失败必须删除临时目录',
      );
      expect(tempBase.listSync(), isEmpty);
    });

    test('已有备份/恢复执行中：busy，不发起下载', () async {
      final gate = Completer<void>();
      final running = LocalBackupService.instance.runExclusiveRestore(() async {
        await gate.future;
        return true;
      });
      await Future<void>.delayed(Duration.zero);

      final result = await build().restoreRemoteBackupExclusive(
        remoteName: 'backup_20261110_120000_123.json',
        configJson: '{"url":"x"}',
      );

      expect(result.status, WebDavRestoreStatus.busy);
      expect(api.downloadedPath, isNull);

      gate.complete();
      await running;
    });
  });

  group('isZipBackupFile', () {
    test('扩展名 .zip 直接判定', () {
      expect(WebDavRestoreService.isZipBackupFile('/tmp/a.zip'), isTrue);
    });

    test('zip 改名 .json 按魔数判定', () {
      final file = File('${tempBase.path}/renamed.json');
      file.writeAsBytesSync([0x50, 0x4B, 0x05, 0x06]);
      expect(WebDavRestoreService.isZipBackupFile(file.path), isTrue);

      file.writeAsStringSync('{"a":1}');
      expect(WebDavRestoreService.isZipBackupFile(file.path), isFalse);
    });

    test('文件不存在按非 zip 处理', () {
      expect(
        WebDavRestoreService.isZipBackupFile(
          '${tempBase.path}/missing.zip.bak',
        ),
        isFalse,
      );
    });
  });
}
