/// WebDavServerService 单元测试（批8：servers 表 + 一次性 prefs 迁移）
///
/// 覆盖：
/// - 旧偏好 → DB 一次性迁移（幂等、标记置位）；
/// - DB 已有配置时忽略旧偏好；
/// - 偏好为空不写行、不置标记（后续仍可从旧备份偏好迁移）；
/// - 迁移标记已置且 DB 为空时不回读偏好（一次性语义）；
/// - 保存保留既有 name/sortNumber；
/// - config 形态不符显式报错；
/// - 回修 P1-1：旧格式备份恢复后的偏好回填（覆盖/不覆盖/空偏好）；
/// - 回修 P2-4：列表元素与字段形态异常显式报错；
/// - 回修 P2-7：§2.28 `webdavServerDelete` 经 BookApi 的删除语义。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/webdav_server_service.dart';

import '../mocks/mocks.dart';

void main() {
  late MockBookApi api;
  late WebDavServerService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockBookApi();
    service = WebDavServerService(api: api);
  });

  Future<List<Map<String, dynamic>>> listServers() async {
    final raw = await api.webdavServersList();
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<bool> migratedFlag() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(WebDavServerService.migratedPrefKey) ?? false;
  }

  test('旧偏好一次性迁移到 DB（id=-1），二次加载不重复写入', () async {
    SharedPreferences.setMockInitialValues({
      'sync_webdav_url': 'https://dav.example.com/',
      'sync_webdav_username': 'user',
      'sync_webdav_password': 'pass',
    });
    service = WebDavServerService(api: api);

    final first = await service.loadSyncServer();
    expect(first.id, WebDavServerService.defaultServerId);
    expect(first.url, 'https://dav.example.com/');
    expect(first.username, 'user');
    expect(first.password, 'pass');
    expect(await migratedFlag(), isTrue, reason: '迁移成功后应置标记');

    final rows = await listServers();
    expect(rows.length, 1, reason: '迁移只写一行');
    expect(rows.single['id'], WebDavServerService.defaultServerId);
    expect(rows.single['name'], WebDavServerService.defaultServerName);
    expect(rows.single['type'], 'WEBDAV');
    final config = jsonDecode(rows.single['config'] as String);
    expect(config['url'], 'https://dav.example.com/');

    // 幂等：再加载仍读 DB，不新增行
    final second = await service.loadSyncServer();
    expect(second.url, 'https://dav.example.com/');
    expect((await listServers()).length, 1);
  });

  test('DB 已有配置时忽略旧偏好', () async {
    await api.webdavServerSave(jsonEncode({
      'id': WebDavServerService.defaultServerId,
      'name': '已有',
      'type': 'WEBDAV',
      'config': jsonEncode({
        'url': 'https://db.example.com/',
        'username': 'db-user',
        'password': 'db-pass',
      }),
      'sortNumber': 0,
    }));
    SharedPreferences.setMockInitialValues({
      'sync_webdav_url': 'https://prefs.example.com/',
      'sync_webdav_username': 'prefs-user',
      'sync_webdav_password': 'prefs-pass',
    });
    service = WebDavServerService(api: api);

    final config = await service.loadSyncServer();
    expect(config.url, 'https://db.example.com/', reason: 'DB 为权威来源');
    expect(config.username, 'db-user');
    expect((await listServers()).length, 1, reason: '不得用偏好覆盖或新增行');
  });

  test('偏好为空不写行、不置迁移标记', () async {
    final config = await service.loadSyncServer();
    expect(config.isEmpty, isTrue);
    expect(await listServers(), isEmpty);
    expect(await migratedFlag(), isFalse, reason: '无偏好可迁移时不应置标记');
  });

  test('迁移标记已置且 DB 为空时不再回读偏好', () async {
    SharedPreferences.setMockInitialValues({
      WebDavServerService.migratedPrefKey: true,
      'sync_webdav_url': 'https://stale.example.com/',
      'sync_webdav_username': 'stale-user',
      'sync_webdav_password': 'stale-pass',
    });
    service = WebDavServerService(api: api);

    final config = await service.loadSyncServer();
    expect(config.isEmpty, isTrue, reason: '一次性迁移后不得复活旧偏好');
    expect(await listServers(), isEmpty);
  });

  test('保存保留既有 name/sortNumber，并更新账号三要素', () async {
    await api.webdavServerSave(jsonEncode({
      'id': WebDavServerService.defaultServerId,
      'name': '自定义名称',
      'type': 'WEBDAV',
      'config': jsonEncode({'url': '', 'username': '', 'password': ''}),
      'sortNumber': 5,
    }));

    final saved = await service.saveSyncServer(
      url: ' https://new.example.com/ ',
      username: ' new-user ',
      password: 'new-pass',
    );
    expect(saved.url, 'https://new.example.com/', reason: 'url 应 trim');
    expect(saved.username, 'new-user');

    final rows = await listServers();
    expect(rows.length, 1);
    expect(rows.single['name'], '自定义名称');
    expect(rows.single['sortNumber'], 5);
    final config = jsonDecode(rows.single['config'] as String);
    expect(config['url'], 'https://new.example.com/');
    expect(config['password'], 'new-pass');
    expect(await migratedFlag(), isTrue);
  });

  test('config 非 JSON 对象时显式报错（不静默当空配置）', () async {
    await api.webdavServerSave(jsonEncode({
      'id': WebDavServerService.defaultServerId,
      'name': '坏配置',
      'type': 'WEBDAV',
      'config': '[]',
      'sortNumber': 0,
    }));

    await expectLater(
      service.loadSyncServer(),
      throwsA(isA<FormatException>()),
    );
  });

  group('旧格式备份恢复后的偏好回填（回修 P1-1）', () {
    Future<void> seedDbRow({
      String url = 'https://old.example.com/',
    }) async {
      await api.webdavServerSave(jsonEncode({
        'id': WebDavServerService.defaultServerId,
        'name': '设备原有',
        'type': 'WEBDAV',
        'config': jsonEncode({
          'url': url,
          'username': 'old-user',
          'password': 'old-pass',
        }),
        'sortNumber': 7,
      }));
    }

    test('v1/v2 备份：恢复所得偏好覆盖已配置设备的 DB 行', () async {
      await seedDbRow();
      // 模拟恢复流程写入 appPrefs 后的偏好（迁移标记已置，loadSyncServer
      // 不会回读偏好——回填必须由 applyLegacyPrefsOverwrite 显式完成）
      SharedPreferences.setMockInitialValues({
        WebDavServerService.migratedPrefKey: true,
        'sync_webdav_url': 'https://restored.example.com/',
        'sync_webdav_username': 'restored-user',
        'sync_webdav_password': 'restored-pass',
      });
      service = WebDavServerService(api: api);

      final applied = await service.applyLegacyPrefsOverwrite();

      expect(applied, isNotNull);
      expect(applied!.url, 'https://restored.example.com/');
      final rows = await listServers();
      expect(rows.length, 1, reason: '覆盖既有行，不新增');
      final config = jsonDecode(rows.single['config'] as String);
      expect(config['url'], 'https://restored.example.com/');
      expect(config['username'], 'restored-user');
      expect(config['password'], 'restored-pass');
      expect(rows.single['name'], '设备原有', reason: 'name 不被回填覆盖');
      expect(rows.single['sortNumber'], 7, reason: 'sortNumber 不被回填覆盖');
    });

    test('v1/v2 备份：DB 无行时按偏好创建 id=-1 行', () async {
      SharedPreferences.setMockInitialValues({
        'sync_webdav_url': 'https://restored.example.com/',
        'sync_webdav_username': 'restored-user',
        'sync_webdav_password': 'restored-pass',
      });
      service = WebDavServerService(api: api);

      final applied = await service.applyLegacyPrefsOverwrite();

      expect(applied, isNotNull);
      final rows = await listServers();
      expect(rows.length, 1);
      expect(rows.single['id'], WebDavServerService.defaultServerId);
      expect(await migratedFlag(), isTrue);
    });

    test('偏好三项全空：不写库、不清既有配置', () async {
      await seedDbRow(url: 'https://keep.example.com/');
      SharedPreferences.setMockInitialValues({});
      service = WebDavServerService(api: api);

      final applied = await service.applyLegacyPrefsOverwrite();

      expect(applied, isNull, reason: '空偏好不得覆盖 DB');
      final rows = await listServers();
      expect(rows.length, 1);
      final config = jsonDecode(rows.single['config'] as String);
      expect(config['url'], 'https://keep.example.com/');
    });

    // [批17d P3-5] 批17c 起新备份的 appPrefs 不再含 sync_webdav_password
    //（设备级秘密整键排除）→ 恢复出的偏好密码恒为空。旧逻辑会把空密码整组
    // 覆盖进 DB，等于清空用户已保存的密码；现在必须读回 DB 现有密码保留。
    test('新备份偏好无密码键：空偏好密码不得清空 DB 现有密码', () async {
      await seedDbRow();
      SharedPreferences.setMockInitialValues({
        WebDavServerService.migratedPrefKey: true,
        'sync_webdav_url': 'https://restored.example.com/',
        'sync_webdav_username': 'restored-user',
      });
      service = WebDavServerService(api: api);

      final applied = await service.applyLegacyPrefsOverwrite();

      expect(applied, isNotNull);
      expect(applied!.url, 'https://restored.example.com/');
      expect(
        applied.password,
        'old-pass',
        reason: '返回给同步流程的配置也必须带 DB 现有密码',
      );
      final rows = await listServers();
      expect(rows.length, 1, reason: '覆盖既有行，不新增');
      final config = jsonDecode(rows.single['config'] as String);
      expect(config['url'], 'https://restored.example.com/');
      expect(config['username'], 'restored-user');
      expect(
        config['password'],
        'old-pass',
        reason: '空偏好密码必须保留 DB 现有密码（红态：被覆盖成空串）',
      );
    });
  });

  group('备份账号来源判定（回修 P1-1）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('legado_servers_detect_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    Future<String> writeBackup(String name, String content) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsString(content);
      return file.path;
    }

    test('v1/v2 备份含 appPrefs 账号键 → legacyPrefs', () async {
      final path = await writeBackup(
        'legacy_v2.json',
        '{"version":2,"backupTime":0,"books":[],"appPrefs":'
        '{"sync_webdav_url":"https://backup.example.com/",'
        '"sync_webdav_username":"u","sync_webdav_password":"p"}}',
      );
      expect(
        await WebDavServerService.backupAccountSource(path),
        WebDavBackupAccountSource.legacyPrefs,
      );
    });

    test('v1/v2 备份无账号键 → none（不用残留偏好覆盖当前配置）', () async {
      final path = await writeBackup(
        'legacy_no_account.json',
        '{"version":2,"backupTime":0,"books":[],'
        '"appPrefs":{"app_theme_mode":"dark"}}',
      );
      expect(
        await WebDavServerService.backupAccountSource(path),
        WebDavBackupAccountSource.none,
      );
    });

    test('v3 备份含 servers 键 → serversSection（优先于 appPrefs）', () async {
      final path = await writeBackup(
        'v3.json',
        '{"version":3,"servers":[],"appPrefs":'
        '{"sync_webdav_url":"https://backup.example.com/"}}',
      );
      expect(
        await WebDavServerService.backupAccountSource(path),
        WebDavBackupAccountSource.serversSection,
      );
    });

    test('非 JSON 路径 / 文件不存在 / 非对象顶层 → none（无法判定）', () async {
      expect(
        await WebDavServerService.backupAccountSource(
          '${tempDir.path}/backup.zip',
        ),
        WebDavBackupAccountSource.none,
        reason: '非 .json 路径不读取',
      );
      expect(
        await WebDavServerService.backupAccountSource(
          '${tempDir.path}/missing.json',
        ),
        WebDavBackupAccountSource.none,
        reason: '读不到按无法判定处理（不回填）',
      );
      final arrayPath = await writeBackup('array.json', '[]');
      expect(
        await WebDavServerService.backupAccountSource(arrayPath),
        WebDavBackupAccountSource.none,
      );
    });
  });

  group('列表形态严格解析（回修 P2-4）', () {
    test('元素非 JSON 对象时显式报错，不静默丢弃', () async {
      final rawApi = MockRustApi();
      when(() => rawApi.webdavServersList()).thenAnswer((_) async => '[1]');
      final strictService = WebDavServerService(api: rawApi);

      await expectLater(
        strictService.loadSyncServer(),
        throwsA(isA<FormatException>()),
      );
    });

    test('字段缺失/类型不符时显式报错（不兜底 0 或空串）', () async {
      for (final raw in [
        '[{"name":"缺 id","type":"WEBDAV","sortNumber":0}]',
        '[{"id":1,"type":"WEBDAV","sortNumber":0}]',
        '[{"id":1,"name":"数值 config","type":"WEBDAV","config":5,"sortNumber":0}]',
        '[{"id":1,"name":"缺 sortNumber","type":"WEBDAV"}]',
      ]) {
        final rawApi = MockRustApi();
        when(() => rawApi.webdavServersList()).thenAnswer((_) async => raw);
        final strictService = WebDavServerService(api: rawApi);
        await expectLater(
          strictService.loadSyncServer(),
          throwsA(isA<FormatException>()),
          reason: '形态不符应显式报错：$raw',
        );
      }
    });
  });

  group('servers CRUD（§2.28，P2-7 删除链路）', () {
    test('webdavServerDelete 经 BookApi：命中 true、重复删除 false', () async {
      final bookApi = MockBookApi();
      final id = await bookApi.webdavServerSave(jsonEncode({
        'id': WebDavServerService.defaultServerId,
        'name': WebDavServerService.defaultServerName,
        'type': 'WEBDAV',
        'config': jsonEncode({
          'url': 'https://dav.example.com/',
          'username': 'u',
          'password': 'p',
        }),
        'sortNumber': 0,
      }));
      expect(id, WebDavServerService.defaultServerId);

      expect(await bookApi.webdavServerDelete(id), isTrue);
      expect(
        await bookApi.webdavServerDelete(id),
        isFalse,
        reason: '未命中返回 false（对齐 Room DELETE 静默语义）',
      );
    });
  });
}
