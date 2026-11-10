// 批40：WebDavBackupService 单测
//
// 覆盖：远端命名（backup_yyyyMMdd_HHmmss.json）、未配置跳过、上传成功/失败、
// 保留数 0（不清理）/N（携带当前文件名与保留数调用 Rust）、清理失败只记录
// 不影响上传结果、清理结果 JSON 解析（含失败项与异常形态）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/services/webdav_backup_candidates.dart';
import 'package:flutter_legado/src/services/webdav_backup_service.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServersRustApi api;
  late SettingsService settings;
  late WebDavBackupService service;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = FakeServersRustApi();
    settings = SettingsService();
    service = WebDavBackupService(api: api, settings: settings);

    when(
      () => api.webdavUploadFile(any(), any(), any()),
    ).thenAnswer((_) async {});
    when(
      () => api.webdavPruneBackups(any(), any(), any()),
    ).thenAnswer((_) async => '{"deleted":[],"failed":[]}');
  });

  /// 预置默认 WebDAV 服务器（id = -1，避免触发偏好迁移）
  void seedDefaultServer({String url = 'https://dav.example.com/'}) {
    api.seedServer(
      config: jsonEncode({'url': url, 'username': 'u', 'password': 'p'}),
    );
  }

  group('buildRemoteFileName', () {
    test('命名 backup_yyyyMMdd_HHmmss_SSS.json（补零）', () {
      expect(
        WebDavBackupService.buildRemoteFileName(DateTime(2026, 1, 2, 3, 4, 5)),
        'backup_20260102_030405_000.json',
      );
      expect(
        WebDavBackupService.buildRemoteFileName(
          DateTime(2026, 12, 31, 23, 59, 59, 7),
        ),
        'backup_20261231_235959_007.json',
      );
    });

    test('同秒不同毫秒 → 文件名不同（批40 回修 P3-9 去重）', () {
      final a = WebDavBackupService.buildRemoteFileName(
        DateTime(2026, 10, 29, 12, 0, 0, 100),
      );
      final b = WebDavBackupService.buildRemoteFileName(
        DateTime(2026, 10, 29, 12, 0, 0, 900),
      );
      expect(a, isNot(b), reason: '同秒连续备份不得覆盖同一远端文件');
    });
  });

  group('resolveConfigJson', () {
    test('未配置返回 null', () async {
      expect(await service.resolveConfigJson(), isNull);
    });

    test('归一化 url 尾斜杠与 remote_dir 首尾单斜杠', () async {
      seedDefaultServer(url: 'https://dav.example.com//');
      await settings.setWebDavRemoteDir('legado');

      final raw = await service.resolveConfigJson();
      expect(raw, isNotNull);
      final map = jsonDecode(raw!) as Map<String, dynamic>;
      expect(map['url'], 'https://dav.example.com');
      expect(map['remote_dir'], '/legado/');
      expect(map['username'], 'u');
      expect(map['password'], 'p');
    });
  });

  group('uploadBackup', () {
    test('未配置 WebDAV → 跳过上传（返回 null，不调用上传）', () async {
      final result = await service.uploadBackup(
        localFilePath: '/tmp/legado_backup_1.json',
      );
      expect(result, isNull);
      verifyNever(() => api.webdavUploadFile(any(), any(), any()));
    });

    test('上传成功且保留数 0 → 不上传清理', () async {
      seedDefaultServer();
      final result = await service.uploadBackup(
        localFilePath: '/tmp/legado_backup_1.json',
        now: DateTime(2026, 10, 29, 12, 0, 0),
      );

      expect(result, isNotNull);
      expect(result!.remoteFileName, 'backup_20261029_120000_000.json');
      expect(result.prune.isEmpty, isTrue);
      expect(result.pruneError, isNull);
      verify(
        () => api.webdavUploadFile(
          any(),
          'backup_20261029_120000_000.json',
          '/tmp/legado_backup_1.json',
        ),
      ).called(1);
      verifyNever(() => api.webdavPruneBackups(any(), any(), any()));
    });

    test('保留数 N → 清理携带当前文件名与 N', () async {
      seedDefaultServer();
      await settings.setWebDavBackupKeepCount(3);
      when(() => api.webdavPruneBackups(any(), any(), any())).thenAnswer(
        (_) async => '{"deleted":["backup_20261001_000000.json"],"failed":[]}',
      );

      final result = await service.uploadBackup(
        localFilePath: '/tmp/legado_backup_1.json',
        now: DateTime(2026, 10, 29, 12, 0, 0),
      );

      expect(result!.prune.deleted, ['backup_20261001_000000.json']);
      verify(
        () =>
            api.webdavPruneBackups(any(), 'backup_20261029_120000_000.json', 3),
      ).called(1);
    });

    test('上传失败 → 异常上抛且不触发清理', () async {
      seedDefaultServer();
      await settings.setWebDavBackupKeepCount(1);
      when(
        () => api.webdavUploadFile(any(), any(), any()),
      ).thenThrow(Exception('网络不可用'));

      await expectLater(
        service.uploadBackup(localFilePath: '/tmp/x.json'),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => api.webdavPruneBackups(any(), any(), any()));
    });

    test('清理失败 → 上传结果保留，仅记录 pruneError', () async {
      seedDefaultServer();
      await settings.setWebDavBackupKeepCount(1);
      when(
        () => api.webdavPruneBackups(any(), any(), any()),
      ).thenThrow(Exception('PROPFIND 失败'));

      final result = await service.uploadBackup(localFilePath: '/tmp/x.json');

      expect(result, isNotNull);
      expect(result!.remoteFileName, endsWith('.json'));
      expect(result.pruneError, isNotNull);
      expect(result.prune.isEmpty, isTrue);
    });

    test('保留数 1 → 只保留当前文件（清理携带 keep=1）', () async {
      seedDefaultServer();
      await settings.setWebDavBackupKeepCount(1);

      final result = await service.uploadBackup(
        localFilePath: '/tmp/legado_backup_1.json',
        now: DateTime(2026, 10, 29, 12, 0, 0),
      );

      expect(result, isNotNull);
      verify(
        () =>
            api.webdavPruneBackups(any(), 'backup_20261029_120000_000.json', 1),
      ).called(1);
    });
  });

  group('备份保留数 clamp（批40 回修 P3-3）', () {
    test('写入超上限 → 归一为 1000', () async {
      await settings.setWebDavBackupKeepCount(5000);
      expect(await settings.getWebDavBackupKeepCount(), 1000);
    });

    test('写入负数 → 归一为 0', () async {
      await settings.setWebDavBackupKeepCount(-3);
      expect(await settings.getWebDavBackupKeepCount(), 0);
    });

    test('已有偏好超上限/负数 → 读取时 clamp', () async {
      SharedPreferences.setMockInitialValues({
        'webDavBackupKeepCount': '999999',
      });
      expect(await SettingsService().getWebDavBackupKeepCount(), 1000);

      SharedPreferences.setMockInitialValues({'webDavBackupKeepCount': '-2'});
      expect(await SettingsService().getWebDavBackupKeepCount(), 0);
    });
  });

  group('WebDavBackupPruneResult.fromJsonString', () {
    test('解析 deleted 与 failed', () {
      final result = WebDavBackupPruneResult.fromJsonString(
        jsonEncode({
          'deleted': ['backup_a.json'],
          'failed': [
            {'name': 'backup_b.json', 'error': 'HTTP 500'},
          ],
        }),
      );
      expect(result.deleted, ['backup_a.json']);
      expect(result.failed.single.name, 'backup_b.json');
      expect(result.failed.single.error, contains('500'));
    });

    test('异常/缺失形态返回空结果（不抛错）', () {
      expect(WebDavBackupPruneResult.fromJsonString('[]').isEmpty, isTrue);
      expect(
        WebDavBackupPruneResult.fromJsonString('{"deleted":null}').isEmpty,
        isTrue,
      );
    });
  });

  // ===== 批11：远端备份列表（网络恢复） =====

  group('listRemoteBackups（批11）', () {
    test('未配置 WebDAV → 空列表且不调用列目录', () async {
      final result = await service.listRemoteBackups();

      expect(result, isEmpty);
      verifyNever(() => api.webdavListDir(any(), any()));
    });

    test('过滤目录/非 backup 前缀/坏时间，并按名称降序', () async {
      seedDefaultServer();
      when(() => api.webdavListDir(any(), any())).thenAnswer(
        (_) async => jsonEncode([
          {
            'name': 'backup_20260101_120000.json',
            'is_dir': false,
            'last_modified': 'Thu, 01 Jan 2026 12:00:00 GMT',
          },
          {
            'name': 'backup_20260102_120000.zip',
            'is_dir': false,
            // 非法 HTTP 日期 → 回退文件名时间
            'last_modified': 'not-a-date',
          },
          {
            'name': 'backup_20260103_120000.json',
            'is_dir': true,
            'last_modified': 'Thu, 01 Jan 2026 12:00:00 GMT',
          },
          {
            'name': 'legado_backup_1.json',
            'is_dir': false,
            'last_modified': 'Thu, 01 Jan 2026 12:00:00 GMT',
          },
          {
            'name': 'backup_20261301_120000.json',
            'is_dir': false,
            'last_modified': 'bad',
          },
          {
            'name': 'backup_..json',
            'is_dir': false,
            'last_modified': 'Thu, 01 Jan 2026 12:00:00 GMT',
          },
        ]),
      );

      final result = await service.listRemoteBackups();

      expect(result.map((e) => e.name), [
        'backup_20260102_120000.zip',
        'backup_20260101_120000.json',
      ], reason: '只保留合法 backup 文件，名称降序');
      expect(
        result.first.lastModifiedMillis,
        DateTime(2026, 1, 2, 12).millisecondsSinceEpoch,
        reason: 'HTTP 日期非法时回退文件名时间',
      );
      expect(
        result.last.lastModifiedMillis,
        HttpDate.parse('Thu, 01 Jan 2026 12:00:00 GMT').millisecondsSinceEpoch,
      );
      verify(() => api.webdavListDir(any(), '')).called(1);
    });

    test('列目录失败原样上抛（调用方提示回退本地恢复）', () async {
      seedDefaultServer();
      when(
        () => api.webdavListDir(any(), any()),
      ).thenThrow(const SocketException('offline'));

      await expectLater(
        service.listRemoteBackups(),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('候选排序/最新（批11 共用解析）', () {
    test('名称降序排序不修改入参', () {
      const a = RemoteBackupCandidate(
        name: 'backup_a.json',
        lastModifiedMillis: 1,
      );
      const b = RemoteBackupCandidate(
        name: 'backup_b.json',
        lastModifiedMillis: 2,
      );
      final input = [a, b];
      final sorted = sortRemoteBackupsByNameDescending(input);

      expect(sorted.map((e) => e.name), ['backup_b.json', 'backup_a.json']);
      expect(input.map((e) => e.name), ['backup_a.json', 'backup_b.json']);
    });

    test('远端最新按 mtime 最大选取（不是名称最大）', () {
      const olderNewerName = RemoteBackupCandidate(
        name: 'backup_z.json',
        lastModifiedMillis: 100,
      );
      const newerOlderName = RemoteBackupCandidate(
        name: 'backup_a.json',
        lastModifiedMillis: 200,
      );

      expect(
        latestRemoteBackupFromCandidates([
          olderNewerName,
          newerOlderName,
        ])?.name,
        'backup_a.json',
      );
    });
  });
}
