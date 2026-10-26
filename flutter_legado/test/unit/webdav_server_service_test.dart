/// WebDavServerService 单元测试（批8：servers 表 + 一次性 prefs 迁移）
///
/// 覆盖：
/// - 旧偏好 → DB 一次性迁移（幂等、标记置位）；
/// - DB 已有配置时忽略旧偏好；
/// - 偏好为空不写行、不置标记（后续仍可从旧备份偏好迁移）；
/// - 迁移标记已置且 DB 为空时不回读偏好（一次性语义）；
/// - 保存保留既有 name/sortNumber；
/// - config 形态不符显式报错。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/webdav_server_service.dart';

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
}
