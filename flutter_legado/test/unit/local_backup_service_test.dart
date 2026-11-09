// 批40：LocalBackupService 单测
//
// 覆盖：进程内互斥（重入直接返回 null/不排队）、备份成功写 lastBackup、
// 上传成功/失败（失败不影响本地备份成功）、未开启上传时跳过、本地备份
// 失败不写 lastBackup。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
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
  late Directory tempDir;

  setUpAll(registerFallbacks);

  setUp(() {
    LocalBackupService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    api = FakeServersRustApi();
    settings = SettingsService();
    tempDir = Directory.systemTemp.createTempSync('local_backup_8a');
    when(() => api.backup(any())).thenAnswer(
      (_) async =>
          '${tempDir.path}${Platform.pathSeparator}legado_backup_1.json',
    );
  });

  tearDown(() {
    LocalBackupService.resetForTest();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

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
      expect(
        await service.runExclusiveRestore(() async => 'restore'),
        'restore',
      );
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
        dirPath: tempDir.path,
        uploadWebDav: true,
        webDavBackupService: webDav,
        now: DateTime(2026, 10, 29, 12),
      );

      expect(
        result.filePath,
        '${tempDir.path}${Platform.pathSeparator}legado_backup_1.json',
      );
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
        dirPath: tempDir.path,
        uploadWebDav: true,
        webDavBackupService: webDav,
      );

      expect(
        result.filePath,
        '${tempDir.path}${Platform.pathSeparator}legado_backup_1.json',
      );
      expect(result.uploaded, isFalse);
      expect(result.uploadError, isNotNull);
      expect(await settings.getLastBackupTime(), greaterThan(0));
    });

    test('未开启上传 → 跳过 WebDAV 且不写上传错误', () async {
      final webDav = _FakeWebDavBackupService(api: api);
      final result = await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
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
        dirPath: tempDir.path,
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
          dirPath: tempDir.path,
          uploadWebDav: false,
        ),
        throwsA(isA<Exception>()),
      );
      expect(await settings.getLastBackupTime(), 0);
    });
  });

  group('备份忽略列表（批8a）', () {
    test('createBackup 使用 backupIgnore 注入 appPrefs，与恢复忽略独立', () async {
      SharedPreferences.setMockInitialValues({
        'themeMode': 'dark',
        'reader_font_size': 20,
        'showRss': false,
        'customFoo': 'bar',
        SettingsService.backupIgnoreStorageKey: jsonEncode({
          'themeMode': true,
          'readConfig': false,
        }),
        SettingsService.restoreIgnoreStorageKey: jsonEncode({
          'readConfig': true,
        }),
      });
      final current =
          '${tempDir.path}${Platform.pathSeparator}legado_backup_test.json';
      when(() => api.backup(any())).thenAnswer((_) async {
        await File(current).writeAsString('{}');
        return current;
      });

      final restoreBefore = await settings.getRestoreIgnoreConfig();
      await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: false,
      );

      final file = jsonDecode(await File(current).readAsString()) as Map;
      final prefs = (file['appPrefs'] as Map).cast<String, dynamic>();
      expect(prefs.containsKey('themeMode'), isFalse, reason: '备份忽略 themeMode');
      expect(prefs['reader_font_size'], 20, reason: '备份忽略 readConfig=false');
      expect(prefs['showRss'], false);
      expect(prefs['customFoo'], 'bar');
      expect(
        prefs.containsKey(SettingsService.backupIgnoreStorageKey),
        isFalse,
      );
      expect(
        prefs.containsKey(SettingsService.restoreIgnoreStorageKey),
        isFalse,
      );
      expect(await settings.getRestoreIgnoreConfig(), restoreBefore);
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          'reader_font_size',
          await settings.getRestoreIgnoreConfig(),
        ),
        isFalse,
        reason: '恢复忽略仍独立生效（readConfig=true 时恢复侧忽略）',
      );
    });
  });

  group('仅保留最新本地备份（批8a）', () {
    Future<String> stubBackupFile(String name) async {
      final path = '${tempDir.path}${Platform.pathSeparator}$name';
      when(() => api.backup(any())).thenAnswer((_) async {
        await File(path).writeAsString('{}');
        return path;
      });
      return path;
    }

    test('默认开启：只保留本次备份，删除旧本地备份', () async {
      final old1 = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_100.json',
      )..writeAsStringSync('old');
      final old2 = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_200.json',
      )..writeAsStringSync('old');
      final current = await stubBackupFile('legado_backup_300.json');

      await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: false,
      );

      expect(File(current).existsSync(), isTrue);
      expect(old1.existsSync(), isFalse);
      expect(old2.existsSync(), isFalse);
    });

    test('开关 false：保留全部本地备份', () async {
      SharedPreferences.setMockInitialValues({'onlyLatestBackup': false});
      final old = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_100.json',
      )..writeAsStringSync('old');
      final current = await stubBackupFile('legado_backup_300.json');

      await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: false,
      );

      expect(old.existsSync(), isTrue);
      expect(File(current).existsSync(), isTrue);
    });

    test('非本项目命名/子目录不删除', () async {
      final otherJson = File(
        '${tempDir.path}${Platform.pathSeparator}other.json',
      )..writeAsStringSync('x');
      final webdavName = File(
        '${tempDir.path}${Platform.pathSeparator}backup_20261029.json',
      )..writeAsStringSync('x');
      final txt = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_1.txt',
      )..writeAsStringSync('x');
      final nonNumericJson = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_abc.json',
      )..writeAsStringSync('x');
      final subdir = Directory(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_dir.json',
      )..createSync();
      final nested = File(
        '${subdir.path}${Platform.pathSeparator}legado_backup_nested.json',
      )..writeAsStringSync('x');
      final current = await stubBackupFile('legado_backup_300.json');

      await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: false,
      );

      expect(File(current).existsSync(), isTrue);
      expect(otherJson.existsSync(), isTrue);
      expect(webdavName.existsSync(), isTrue);
      expect(txt.existsSync(), isTrue);
      expect(nonNumericJson.existsSync(), isTrue, reason: '文件名非纯数字不匹配');
      expect(subdir.existsSync(), isTrue);
      expect(nested.existsSync(), isTrue);
    });

    test('旧备份删除失败不抛出，备份仍成功', () async {
      final old = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_100.json',
      )..writeAsStringSync('old');
      final current = await stubBackupFile('legado_backup_300.json');
      final service = LocalBackupService(
        deleteFileForTest: (_) async =>
            throw const FileSystemException('denied'),
      );

      final result = await service.createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: false,
      );

      expect(result.filePath, current);
      expect(old.existsSync(), isTrue, reason: '删除失败保留旧文件');
    });

    test('上传失败仍清理旧备份（上传尝试结束后清理）', () async {
      final old = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_100.json',
      )..writeAsStringSync('old');
      final current = await stubBackupFile('legado_backup_300.json');
      final webDav = _FakeWebDavBackupService(api: api)
        ..error = Exception('网络不可用');

      final result = await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: true,
        webDavBackupService: webDav,
      );

      expect(result.uploadError, isNotNull);
      expect(old.existsSync(), isFalse);
      expect(File(current).existsSync(), isTrue);
    });

    test('dirPath 末尾带分隔符：本次备份不被误删', () async {
      final dirPath = '${tempDir.path}${Platform.pathSeparator}';
      final old = File(
        '${tempDir.path}${Platform.pathSeparator}legado_backup_100.json',
      )..writeAsStringSync('old');
      // 模拟 Windows 盘根拼接：dirPath 尾分隔符 + 文件名 → 双分隔符路径
      final current = '${dirPath}legado_backup_300.json';
      when(() => api.backup(any())).thenAnswer((_) async {
        await File(current).writeAsString('{}');
        return current;
      });

      await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: dirPath,
        uploadWebDav: false,
      );

      expect(File(current).existsSync(), isTrue, reason: '本次备份必须保留');
      expect(old.existsSync(), isFalse, reason: '旧备份仍应清理');
    });
  });

  group('备份忽略本地书（批8a 回修 P2-1）', () {
    Future<String> stubBackupJson(Map<String, dynamic> data) async {
      final path =
          '${tempDir.path}${Platform.pathSeparator}legado_backup_500.json';
      when(() => api.backup(any())).thenAnswer((_) async {
        await File(path).writeAsString(jsonEncode(data));
        return path;
      });
      return path;
    }

    Map<String, dynamic> backupWithLocalBooks() => {
      'books': [
        {'name': 'originLocal', 'origin': 'loc_book', 'type': 8},
        {
          'name': 'webDavLocal',
          'origin': 'webDav::https://host/a.epub',
          'type': 8,
        },
        {'name': 'bitLocal', 'origin': '', 'type': 0x1000 | 8},
        {'name': 'online', 'origin': 'https://host/b', 'type': 8},
        {'name': 'noTypeLocal', 'origin': 'loc_book'},
      ],
    };

    test('backupIgnore.localBook=true：备份 JSON books 不含本地书', () async {
      SharedPreferences.setMockInitialValues({
        SettingsService.backupIgnoreStorageKey: jsonEncode({'localBook': true}),
      });
      final path = await stubBackupJson(backupWithLocalBooks());

      await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: false,
      );

      final decoded =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final names = (decoded['books'] as List)
          .map((item) => (item as Map)['name'])
          .toList();
      expect(names, ['online']);
    });

    test('仅 restoreIgnore.localBook=true：备份侧不过滤', () async {
      SharedPreferences.setMockInitialValues({
        SettingsService.restoreIgnoreStorageKey: jsonEncode({
          'localBook': true,
        }),
      });
      final path = await stubBackupJson(backupWithLocalBooks());

      await LocalBackupService().createBackup(
        api: api,
        settings: settings,
        dirPath: tempDir.path,
        uploadWebDav: false,
      );

      final decoded =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      expect((decoded['books'] as List), hasLength(5));
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          'localBook',
          await settings.getRestoreIgnoreConfig(),
        ),
        isTrue,
      );
    });

    test('过滤失败 fail-closed：删除未过滤文件且不写 lastBackup', () async {
      SharedPreferences.setMockInitialValues({
        SettingsService.backupIgnoreStorageKey: jsonEncode({'localBook': true}),
      });
      final path =
          '${tempDir.path}${Platform.pathSeparator}legado_backup_600.json';
      when(() => api.backup(any())).thenAnswer((_) async {
        await File(path).writeAsString('{not json');
        return path;
      });
      final webDav = _FakeWebDavBackupService(api: api);

      await expectLater(
        LocalBackupService().createBackup(
          api: api,
          settings: settings,
          dirPath: tempDir.path,
          uploadWebDav: true,
          webDavBackupService: webDav,
        ),
        throwsA(isA<StateError>()),
      );

      expect(File(path).existsSync(), isFalse, reason: '不得保留未过滤备份');
      expect(webDav.calls, 0, reason: '过滤失败不得上传');
      expect(await settings.getLastBackupTime(), 0);
    });
  });
}
