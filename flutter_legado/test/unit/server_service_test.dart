/// ServerService 单元测试（批18a：远程书库服务器列表迁移到 servers 表）
///
/// 覆盖：
/// - 列表：单行 config 非法只标记该行无效、整表形态异常显式报错；
/// - 保存：id=0 交给 Rust 分配、正数 id 保留且沿用 sortNumber、id=-1 拒绝；
/// - 删除：正数 id 走 FFI、id=-1 拒绝；
/// - 一次性迁移：字段正确、幂等、非法 JSON 不置标记、id=-1 跳过、id=0 分配、
///   重复 id 重新分配、中途失败重试、密码保留、旧偏好保留不删；
/// - 旧格式备份判定与密码索引。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/server_service.dart';

import '../mocks/mocks.dart';

/// 可在第 N 次保存时抛错的 servers 内存实现（模拟中途失败）
class _FlakyServersRustApi extends FakeServersRustApi {
  int failOnCall = -1;
  int saveCalls = 0;

  @override
  Future<int> webdavServerSave(String serverJson) async {
    saveCalls++;
    if (saveCalls == failOnCall) {
      throw StateError('模拟保存失败');
    }
    return super.webdavServerSave(serverJson);
  }
}

/// 统计整表列举次数（钉住迁移不再逐台查全表）
class _CountingServersRustApi extends FakeServersRustApi {
  int listCalls = 0;

  @override
  Future<String> webdavServersList() {
    listCalls++;
    return super.webdavServersList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServersRustApi api;
  late ServerService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = FakeServersRustApi();
    service = ServerService(api: api);
  });

  Future<List<Map<String, dynamic>>> rawRows() async {
    final raw = await api.webdavServersList();
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<bool> migratedFlag() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(ServerService.migratedPrefKey) ?? false;
  }

  group('listServers（单行容错）', () {
    test('config 非法的行只标记无效，不抛错、不拖垮其它行', () async {
      api.seedServer(
        id: 1,
        name: '正常',
        config: jsonEncode({
          'url': 'https://dav.example.com/',
          'username': 'u',
          'password': 'p',
        }),
      );
      api.seedServer(id: 2, name: '数组配置', config: '[]');
      api.seedServer(id: 3, name: '坏 JSON', config: 'not-json');
      api.seedServer(id: 4, name: '空配置', config: null);
      // 非字符串 config（契约外形态）同样只标记无效，不拖垮整页
      api.servers.add({
        'id': 5,
        'name': '数值配置',
        'type': 'WEBDAV',
        'config': 5,
        'sortNumber': 0,
      });

      final rows = await service.listServers();

      expect(rows, hasLength(5));
      expect(rows[0].isValid, isTrue);
      expect(rows[0].url, 'https://dav.example.com/');
      expect(rows[0].username, 'u');
      expect(rows[0].password, 'p');
      for (final row in rows.skip(1)) {
        expect(row.isValid, isFalse, reason: 'id=${row.id} 应标记无效');
        expect(row.url, '');
        expect(row.password, '');
      }
    });

    test('非 WEBDAV 类型标记无效', () async {
      api.seedServer(id: 9, name: '未知类型', type: 'FTP', config: '{}');
      final rows = await service.listServers();
      expect(rows.single.isValid, isFalse);
    });

    test('config 缺少 url（"{}" / 空白 url）标记无效', () async {
      api.seedServer(id: 10, name: '空对象', config: '{}');
      api.seedServer(
        id: 11,
        name: '空白 url',
        config: jsonEncode({'url': '   ', 'username': 'u', 'password': 'p'}),
      );
      final rows = await service.listServers();
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.isValid, isFalse, reason: 'id=${row.id} 无 url 应标记无效');
      }
    });

    test('整表非 JSON 数组时显式报错', () async {
      final rawApi = MockRustApi();
      when(() => rawApi.webdavServersList())
          .thenAnswer((_) async => '{"not":"array"}');
      final strict = ServerService(api: rawApi);
      await expectLater(
        strict.listServers(),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('saveServer / deleteServer', () {
    test('新建（id=0）由 Rust 分配正数主键，type=WEBDAV、config 字段正确', () async {
      final saved = await service.saveServer(
        id: 0,
        name: ' 我的网盘 ',
        url: ' https://dav.example.com/ ',
        username: ' alice ',
        password: 'secret',
      );

      expect(saved.id, greaterThan(0));
      expect(saved.name, '我的网盘');
      expect(saved.url, 'https://dav.example.com/');
      expect(saved.sortNumber, 0);

      final row = (await rawRows()).single;
      expect(row['id'], saved.id);
      expect(row['type'], 'WEBDAV');
      expect(row['sortNumber'], 0);
      final config = jsonDecode(row['config'] as String);
      expect(config['url'], 'https://dav.example.com/');
      expect(config['username'], 'alice');
      expect(config['password'], 'secret');
    });

    test('编辑正数 id 原样保留，并沿用既有 sortNumber', () async {
      api.seedServer(
        id: 5,
        name: '旧名',
        config: jsonEncode({'url': 'https://old/', 'username': '', 'password': ''}),
        sortNumber: 9,
      );

      final saved = await service.saveServer(
        id: 5,
        name: '新名',
        url: 'https://new.example.com/',
        username: 'u',
        password: 'p',
      );

      expect(saved.id, 5);
      final row = (await rawRows()).single;
      expect(row['id'], 5);
      expect(row['name'], '新名');
      expect(row['sortNumber'], 9, reason: '编辑不得重置排序号');
    });

    test('id=-1 拒绝保存与删除（默认 WebDAV 固定身份）', () async {
      await expectLater(
        service.saveServer(
          id: ServerService.defaultServerId,
          name: '默认',
          url: 'https://dav/',
          username: '',
          password: '',
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        service.deleteServer(ServerService.defaultServerId),
        throwsA(isA<ArgumentError>()),
      );
      expect(await rawRows(), isEmpty);
    });

    test('删除正数 id 走 FFI', () async {
      api.seedServer(id: 7, name: '待删');
      expect(await service.deleteServer(7), isTrue);
      expect(await rawRows(), isEmpty);
      expect(await service.deleteServer(7), isFalse);
    });
  });

  group('migrateLegacyPrefs', () {
    test('两条旧偏好 → 两行，字段正确并置标记，旧偏好保留', () async {
      const legacy = [
        {
          'id': 1001,
          'name': '网盘A',
          'url': 'https://a.example.com/',
          'username': 'ua',
          'password': 'pa',
        },
        {
          'id': 1002,
          'name': '网盘B',
          'url': 'https://b.example.com/',
          'username': 'ub',
          'password': 'pb',
        },
      ];
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode(legacy),
        'remote_server_id': 1001,
      });
      service = ServerService(api: api);

      expect(await service.migrateLegacyPrefs(), isTrue);

      final rows = await rawRows();
      expect(rows, hasLength(2));
      expect(rows.map((e) => e['id']), [1001, 1002]);
      final configA = jsonDecode(rows[0]['config'] as String);
      expect(configA['url'], 'https://a.example.com/');
      expect(configA['username'], 'ua');
      expect(configA['password'], 'pa');
      expect(await migratedFlag(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ServerService.legacyPrefKey), jsonEncode(legacy),
          reason: '旧键保留不删（回滚安全）');
      expect(prefs.getInt('remote_server_id'), 1001);
    });

    test('幂等：重复执行不新增行', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 2001,
            'name': '网盘',
            'url': 'https://dav/',
            'username': 'u',
            'password': 'p',
          },
        ]),
      });
      service = ServerService(api: api);

      expect(await service.migrateLegacyPrefs(), isTrue);
      expect(await service.migrateLegacyPrefs(), isFalse, reason: '标记已置');
      expect(await service.migrateLegacyPrefs(force: true), isTrue);
      expect(await rawRows(), hasLength(1), reason: '同 id REPLACE');
    });

    test('非数组 / 坏 JSON 不置标记（下次重试）', () async {
      for (final raw in ['not-json', '{"a":1}', '[1,2]']) {
        SharedPreferences.setMockInitialValues({
          ServerService.legacyPrefKey: raw,
        });
        final localApi = FakeServersRustApi();
        final localService = ServerService(api: localApi);
        expect(await localService.migrateLegacyPrefs(), isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(ServerService.migratedPrefKey) ?? false,
          isFalse,
          reason: '形态非法不得置标记：$raw',
        );
        expect(localApi.servers, isEmpty);
      }
    });

    test('id=-1 跳过，id=0 交给 Rust 分配', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': -1,
            'name': '默认',
            'url': 'https://default/',
            'username': 'u',
            'password': 'p',
          },
          {
            'id': 0,
            'name': '新建',
            'url': 'https://new/',
            'username': 'u2',
            'password': 'p2',
          },
        ]),
      });
      service = ServerService(api: api);

      expect(await service.migrateLegacyPrefs(), isTrue);

      final rows = await rawRows();
      expect(rows, hasLength(1), reason: 'id=-1 不迁移');
      expect(rows.single['id'], greaterThan(0));
      expect(rows.single['name'], '新建');
    });

    test('重复 id：后续条目重新分配，不覆盖首条', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 3001,
            'name': '首条',
            'url': 'https://first/',
            'username': 'u',
            'password': 'p',
          },
          {
            'id': 3001,
            'name': '重复',
            'url': 'https://second/',
            'username': 'u2',
            'password': 'p2',
          },
        ]),
      });
      service = ServerService(api: api);

      expect(await service.migrateLegacyPrefs(), isTrue);

      final rows = await rawRows();
      expect(rows, hasLength(2));
      final ids = rows.map((e) => e['id'] as int).toSet();
      expect(ids, contains(3001));
      expect(ids.where((id) => id != 3001), hasLength(1),
          reason: '重复条目应分配新主键');
      final first = rows.firstWhere((e) => e['id'] == 3001);
      expect(first['name'], '首条');
    });

    test('密码：prefs 为空时保留 DB 同 id 行既有密码', () async {
      api.seedServer(
        id: 4001,
        name: '旧',
        config: jsonEncode({
          'url': 'https://old/',
          'username': 'u',
          'password': 'db-password',
        }),
      );
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 4001,
            'name': '新名',
            'url': 'https://new/',
            'username': 'u2',
            'password': '',
          },
        ]),
      });
      service = ServerService(api: api);

      expect(await service.migrateLegacyPrefs(), isTrue);

      final config = jsonDecode((await rawRows()).single['config'] as String);
      expect(config['password'], 'db-password');
      expect(config['url'], 'https://new/');
    });

    test('中途失败不置标记；重试后全部落库且不重复', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 5001,
            'name': 'A',
            'url': 'https://a/',
            'username': 'u',
            'password': 'p',
          },
          {
            'id': 5002,
            'name': 'B',
            'url': 'https://b/',
            'username': 'u',
            'password': 'p',
          },
        ]),
      });
      final flaky = _FlakyServersRustApi()..failOnCall = 2;
      final flakyService = ServerService(api: flaky);

      await expectLater(
        flakyService.migrateLegacyPrefs(),
        throwsA(isA<StateError>()),
      );
      expect(await migratedFlag(), isFalse, reason: '未全部成功不得置标记');

      flaky.failOnCall = -1;
      expect(await flakyService.migrateLegacyPrefs(), isTrue);
      final rows = (jsonDecode(await flaky.webdavServersList()) as List);
      expect(rows, hasLength(2), reason: '重试不得重复首条');
    });

    test('复用路径：name 带空格 + 中途失败，重试复用上次分配行不重复', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 0,
            'name': ' 网盘A ',
            'url': ' https://a/ ',
            'username': ' u ',
            'password': 'p',
          },
          {
            'id': 0,
            'name': ' 网盘B ',
            'url': ' https://b/ ',
            'username': ' u ',
            'password': 'p',
          },
        ]),
      });
      final flaky = _FlakyServersRustApi()..failOnCall = 2;
      final flakyService = ServerService(api: flaky);

      await expectLater(
        flakyService.migrateLegacyPrefs(),
        throwsA(isA<StateError>()),
      );
      // 首条已分配主键落库（模拟上次迁移中断）
      expect(flaky.servers, hasLength(1));
      final firstId = (flaky.servers.single['id'] as num).toInt();

      flaky.failOnCall = -1;
      expect(await flakyService.migrateLegacyPrefs(), isTrue);

      expect(flaky.servers, hasLength(2), reason: '重试不得重复首条');
      final reused = flaky.servers.singleWhere(
        (e) => (e['id'] as num).toInt() == firstId,
      );
      expect(reused['name'], '网盘A', reason: '复用行按 trim 后的名称匹配');
    });

    test('prefs 密码优先于 DB 同 id 行', () async {
      api.seedServer(
        id: 6001,
        name: '旧',
        config: jsonEncode({
          'url': 'https://old/',
          'username': 'u',
          'password': 'db-password',
        }),
      );
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 6001,
            'name': '新',
            'url': 'https://new/',
            'username': 'u',
            'password': 'prefs-password',
          },
        ]),
      });
      service = ServerService(api: api);

      expect(await service.migrateLegacyPrefs(), isTrue);

      final config = jsonDecode((await rawRows()).single['config'] as String);
      expect(config['password'], 'prefs-password');
    });

    test('非数字 id 判型为形态非法：不抛错、不置标记、不写库', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 'abc',
            'name': '坏 id',
            'url': 'https://a/',
            'username': 'u',
            'password': 'p',
          },
        ]),
      });
      service = ServerService(api: api);

      expect(await service.migrateLegacyPrefs(), isFalse);
      expect(await migratedFlag(), isFalse, reason: '形态非法不得置标记');
      expect(api.servers, isEmpty);
    });

    test('迁移只读一次整表（不逐台 _findById，消除 O(N²)）', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          for (var i = 1; i <= 3; i++)
            {
              'id': 8000 + i,
              'name': '网盘$i',
              'url': 'https://$i/',
              'username': 'u',
              'password': 'p',
            },
        ]),
      });
      final counting = _CountingServersRustApi();
      final countingService = ServerService(api: counting);

      expect(await countingService.migrateLegacyPrefs(), isTrue);

      expect(counting.servers, hasLength(3));
      expect(counting.listCalls, 1, reason: '迁移循环复用已读快照');
    });

    test('恢复后强制迁移失败：复位标记返回 false，下次启动可重试', () async {
      SharedPreferences.setMockInitialValues({
        ServerService.legacyPrefKey: jsonEncode([
          {
            'id': 7001,
            'name': '恢复网盘',
            'url': 'https://restore/',
            'username': 'u',
            'password': 'p',
          },
        ]),
        ServerService.migratedPrefKey: true,
      });
      final flaky = _FlakyServersRustApi()..failOnCall = 1;
      final flakyService = ServerService(api: flaky);

      expect(await flakyService.forceMigrateAfterRestore(), isFalse);
      expect(await migratedFlag(), isFalse, reason: '失败后必须复位标记');

      flaky.failOnCall = -1;
      expect(
        await flakyService.migrateLegacyPrefs(),
        isTrue,
        reason: '标记复位后下次启动可重试',
      );
      expect(flaky.servers, hasLength(1));
    });
  });

  group('localPasswordIndex', () {
    test('按 id 与 url+username 建立密码索引', () async {
      api.seedServer(
        id: 1,
        config: jsonEncode({
          'url': 'https://a/',
          'username': 'ua',
          'password': 'pa',
        }),
      );
      api.seedServer(
        id: 2,
        config: jsonEncode({
          'url': 'https://b/',
          'username': 'ub',
          'password': 'pb',
        }),
      );
      api.seedServer(id: 3, config: null);

      final index = await service.localPasswordIndex();
      expect(index.byId, {1: 'pa', 2: 'pb'});
      expect(
        index.byEndpoint[LocalServerPasswordIndex.endpointKey('https://a/', 'ua')],
        'pa',
      );
    });
  });

  group('backupNeedsLegacyRemoteServerMigration', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('legado_18a_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    Future<String> writeBackup(String name, String content) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsString(content);
      return file.path;
    }

    test('无 servers 段 + appPrefs 携带 remote_servers → true', () async {
      final path = await writeBackup(
        'v2.json',
        '{"version":2,"appPrefs":{"remote_servers":"[]"}}',
      );
      expect(
        await ServerService.backupNeedsLegacyRemoteServerMigration(path),
        isTrue,
      );
    });

    test('servers 仅 id=-1 → true', () async {
      final path = await writeBackup(
        'v3_default.json',
        '{"version":3,"servers":[{"id":-1}],'
        '"appPrefs":{"remote_servers":"[]"}}',
      );
      expect(
        await ServerService.backupNeedsLegacyRemoteServerMigration(path),
        isTrue,
      );
    });

    test('servers 含正数 id → false（以备份 servers 段为准）', () async {
      final path = await writeBackup(
        'v3_servers.json',
        '{"version":3,"servers":[{"id":-1},{"id":1}],'
        '"appPrefs":{"remote_servers":"[]"}}',
      );
      expect(
        await ServerService.backupNeedsLegacyRemoteServerMigration(path),
        isFalse,
      );
    });

    test('appPrefs 的 remote_servers 形态非法 → false（不得强制迁移旧 prefs）', () async {
      for (final value in ['not-json', '{"a":1}', '[1,2]']) {
        final path = await writeBackup(
          'bad_legacy.json',
          jsonEncode({
            'version': 2,
            'appPrefs': {'remote_servers': value},
          }),
        );
        expect(
          await ServerService.backupNeedsLegacyRemoteServerMigration(path),
          isFalse,
          reason: '形态非法时不强制迁移：$value',
        );
      }
    });

    test('备份未携带 remote_servers / 非 json / 非对象 → false', () async {
      final noPrefs = await writeBackup(
        'no_prefs.json',
        '{"version":3,"servers":[]}',
      );
      expect(
        await ServerService.backupNeedsLegacyRemoteServerMigration(noPrefs),
        isFalse,
      );
      expect(
        await ServerService.backupNeedsLegacyRemoteServerMigration(
          '${tempDir.path}/backup.zip',
        ),
        isFalse,
      );
      final array = await writeBackup('array.json', '[]');
      expect(
        await ServerService.backupNeedsLegacyRemoteServerMigration(array),
        isFalse,
      );
    });
  });
}
