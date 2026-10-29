// 批40：LocalBackupService 单测
//
// 覆盖：进程内互斥（重入直接返回 null/不排队）、备份成功写 lastBackup、
// 上传成功/失败（失败不影响本地备份成功）、未开启上传时跳过、本地备份
// 失败不写 lastBackup。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/services/webdav_backup_service.dart';

import '../mocks/mocks.dart';

/// 假 WebDAV 备份服务：记录调用并可注入异常/结果
class _FakeWebDavBackupService extends WebDavBackupService {
  _FakeWebDavBackupService({required super.api});

  int calls = 0;
  Object? error;
  WebDavBackupUploadResult? result;
  bool returnNull = false;

  @override
  Future<WebDavBackupUploadResult?> uploadBackup({
    required String localFilePath,
    DateTime? now,
  }) async {
    calls++;
    final e = error;
    if (e != null) throw e;
    if (returnNull) return null;
    return result ??
        const WebDavBackupUploadResult(
          remoteFileName: 'backup_20261029_120000.json',
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServersRustApi api;
  late SettingsService settings;

  setUpAll(registerFallbacks);

  setUp(() {
    LocalBackupService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    api = FakeServersRustApi();
    settings = SettingsService();
    when(() => api.backup(any()))
        .thenAnswer((_) async => '/tmp/legado_backup_1.json');
  });

  tearDown(LocalBackupService.resetForTest);

  group('互斥锁', () {
    test('已有任务执行中 → 新触发直接返回 null（不排队）', () async {
      final service = LocalBackupService();
      final gate = Completer<void>();
      final first = service.runExclusive(() async {
        await gate.future;
        return 'first';
      });
      // 让第一个任务进入执行体
      await Future<void>.delayed(Duration.zero);

      final second = await service.runExclusive(() async => 'second');
      expect(second, isNull, reason: '重入不得执行第二个任务');
      expect(LocalBackupService.isRunning, isTrue);

      gate.complete();
      expect(await first, 'first');
      expect(LocalBackupService.isRunning, isFalse);
    });

    test('任务抛异常后锁释放', () async {
      final service = LocalBackupService();
      await expectLater(
        service.runExclusive<void>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(LocalBackupService.isRunning, isFalse);
      expect(await service.runExclusive(() async => 1), 1);
    });
  });

  group('恢复互斥（批40 回修 P2-2）', () {
    test('恢复进行中 → 备份触发返回 null（自动备份 busy）', () async {
      final service = LocalBackupService();
      final gate = Completer<void>();
      final restore = service.runExclusiveRestore(() async {
        await gate.future;
        return 'restore';
      });
      await Future<void>.delayed(Duration.zero);

      expect(LocalBackupService.isRestoring, isTrue);
      expect(await service.runExclusive(() async => 'backup'), isNull);

      gate.complete();
      expect(await restore, 'restore');
      expect(LocalBackupService.isRestoring, isFalse);
      // 恢复结束后锁释放，备份可正常执行
      expect(await service.runExclusive(() async => 'backup'), 'backup');
    });

    test('备份进行中 → 恢复触发返回 null（不并发写库）', () async {
      final service = LocalBackupService();
      final gate = Completer<void>();
      final backup = service.runExclusive(() async {
        await gate.future;
        return 'backup';
      });
      await Future<void>.delayed(Duration.zero);

      expect(await service.runExclusiveRestore(() async => 'restore'), isNull);

      gate.complete();
      expect(await backup, 'backup');
      expect(await service.runExclusiveRestore(() async => 'restore'), 'restore');
    });

    test('恢复重入 → 直接返回 null 且不排队', () async {
      final service = LocalBackupService();
      final gate = Completer<void>();
      final first = service.runExclusiveRestore(() async {
        await gate.future;
        return 'first';
      });
      await Future<void>.delayed(Duration.zero);

      expect(await service.runExclusiveRestore(() async => 'second'), isNull);

      gate.complete();
      expect(await first, 'first');
      expect(LocalBackupService.isBusy, isFalse);
    });
  });

  group('createBackup', () {
    test('上传成功 → 返回上传结果并写 lastBackup', () async {
      final webDav = _FakeWebDavBackupService(api: api);
      final result = await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: '/tmp',
        uploadWebDav: true,
        webDavBackupService: webDav,
        now: DateTime(2026, 10, 29, 12),
      );

      expect(result.filePath, '/tmp/legado_backup_1.json');
      expect(result.uploaded, isTrue);
      expect(result.uploadError, isNull);
      expect(webDav.calls, 1);
      expect(
        await settings.getLastBackupTime(),
        DateTime(2026, 10, 29, 12).millisecondsSinceEpoch,
      );
    });

    test('上传失败 → 本地备份仍成功，记录 uploadError 且写 lastBackup', () async {
      final webDav = _FakeWebDavBackupService(api: api)
        ..error = Exception('网络不可用');
      final result = await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: '/tmp',
        uploadWebDav: true,
        webDavBackupService: webDav,
      );

      expect(result.filePath, '/tmp/legado_backup_1.json');
      expect(result.uploaded, isFalse);
      expect(result.uploadError, isNotNull);
      expect(await settings.getLastBackupTime(), greaterThan(0));
    });

    test('未开启上传 → 跳过 WebDAV 且不写上传错误', () async {
      final webDav = _FakeWebDavBackupService(api: api);
      final result = await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: '/tmp',
        uploadWebDav: false,
        webDavBackupService: webDav,
      );

      expect(result.uploadSkipped, isTrue);
      expect(result.uploadError, isNull);
      expect(webDav.calls, 0);
      expect(await settings.getLastBackupTime(), greaterThan(0));
    });

    test('未配置 WebDAV → 上传跳过（uploadSkipped）', () async {
      final webDav = _FakeWebDavBackupService(api: api)..returnNull = true;
      final result = await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: '/tmp',
        uploadWebDav: true,
        webDavBackupService: webDav,
      );

      expect(result.uploaded, isFalse);
      expect(result.uploadSkipped, isTrue);
      expect(result.uploadError, isNull);
    });

    test('本地备份失败 → 异常上抛且 lastBackup 不更新', () async {
      when(() => api.backup(any())).thenThrow(Exception('磁盘写入失败'));
      await expectLater(
        LocalBackupService().createBackup(
          api: api,
          settings: settings,
          dirPath: '/tmp',
          uploadWebDav: false,
        ),
        throwsA(isA<Exception>()),
      );
      expect(await settings.getLastBackupTime(), 0);
    });
  });
}
