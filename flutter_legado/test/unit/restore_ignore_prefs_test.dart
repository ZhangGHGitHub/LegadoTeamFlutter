import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RestoreIgnorePrefs.keyIsNotIgnore', () {
    test('默认全部可备份', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.showRss, const {}),
        isTrue,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('reader_font_size', const {}),
        isTrue,
      );
    });

    test('alwaysIgnore 永远跳过', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.launcherIcon, const {}),
        isFalse,
      );
      // 本地密码属于设备级秘密，任何 ignore 组合下都不得进备份
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.localPassword, const {}),
        isFalse,
      );
    });

    test('勾选 readConfig 跳过阅读键', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          'reader_font_size',
          {'readConfig': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.showRss,
          {'readConfig': true},
        ),
        isTrue,
      );
    });

    test('勾选 themeMode / showRss / threadCount / bookshelfLayout', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          RestoreIgnorePrefs.themeModeStorageKey,
          {'themeMode': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.showRss,
          {'showRss': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.threadCount,
          {'threadCount': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          RestoreIgnorePrefs.bookshelfLayoutStorageKey,
          {'bookshelfLayout': true},
        ),
        isFalse,
      );
    });

    test('勾选 themeConfig / coverConfig', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.cPrimary,
          {'themeConfig': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.coverShowName,
          {'coverConfig': true},
        ),
        isFalse,
      );
    });
  });

  group('RestoreIgnorePrefs collect/apply', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        PrefKeys.showRss: false,
        PrefKeys.threadCount: 8,
        'reader_font_size': 20.0,
        PrefKeys.launcherIcon: 'icon_a',
        PrefKeys.localPassword: '1234',
      });
    });

    test('collect 按 ignore 过滤并跳过 alwaysIgnore', () async {
      final collected = await RestoreIgnorePrefs.collectForBackup({
        'readConfig': true,
      });
      expect(collected.containsKey(PrefKeys.showRss), isTrue);
      expect(collected[PrefKeys.showRss], isFalse);
      expect(collected[PrefKeys.threadCount], 8);
      expect(collected.containsKey('reader_font_size'), isFalse);
      expect(collected.containsKey(PrefKeys.launcherIcon), isFalse);
      // 本地密码不写入备份 appPrefs（避免明文口令随备份文件外流）
      expect(collected.containsKey(PrefKeys.localPassword), isFalse);
    });

    test('本地密码不被备份值覆盖', () async {
      await RestoreIgnorePrefs.applyFromBackup(
        {PrefKeys.localPassword: 'backup-password'},
        const {},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PrefKeys.localPassword),
        '1234',
        reason: '本机既有本地密码必须保持不变',
      );
    });

    test('apply 尊重 ignore 不覆盖本地项', () async {
      await RestoreIgnorePrefs.applyFromBackup(
        {
          PrefKeys.showRss: true,
          PrefKeys.threadCount: 32,
          'reader_font_size': 14.0,
        },
        {
          'showRss': true,
          'readConfig': false,
        },
      );
      final prefs = await SharedPreferences.getInstance();
      // showRss 忽略 → 保持 mock 初始 false
      expect(prefs.getBool(PrefKeys.showRss), isFalse);
      expect(prefs.getInt(PrefKeys.threadCount), 32);
      expect(prefs.getDouble('reader_font_size'), 14.0);
    });
  });

  // ─── 批17c P2-3：其他敏感偏好不得明文进备份 ──────────────────────────
  group('敏感偏好不进备份（P2-3）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        PrefKeys.localPassword: 'app-lock-secret',
        'sync_webdav_password': 'webdav-secret',
        'remote_servers':
            '[{"id":1,"name":"我的网盘","url":"https://dav.example/",'
                '"username":"alice","password":"dav-secret"}]',
        PrefKeys.showRss: false,
      });
    });

    test('WebDAV 同步密码恒不备份、不被备份值覆盖', () async {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          'sync_webdav_password',
          const {},
        ),
        isFalse,
        reason: '设备级秘密在任何 ignore 组合下都不得进备份',
      );
      final collected = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(collected.containsKey('sync_webdav_password'), isFalse);

      await RestoreIgnorePrefs.applyFromBackup(
        {'sync_webdav_password': 'backup-secret'},
        const {},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('sync_webdav_password'),
        'webdav-secret',
        reason: '本机 WebDAV 密码必须保持不变',
      );
    });

    test('远程书库服务器不写入新备份（改由 servers 表承载）', () async {
      final collected = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(
        collected.containsKey('remote_servers'),
        isFalse,
        reason: '批18a 起新备份由 servers 段承载，旧偏好整键不导出',
      );
      expect(
        RestoreIgnorePrefs.backupExcludedKeys,
        contains('remote_servers'),
      );
      expect(
        RestoreIgnorePrefs.alwaysIgnoreKeys,
        isNot(contains('remote_servers')),
        reason: '旧备份仍需可读：不得塞进 alwaysIgnoreKeys',
      );
    });

    test('备份 JSON（appPrefs）扫描：不含任何敏感明文', () async {
      final appPrefs = await RestoreIgnorePrefs.collectForBackup(const {});
      final backupJson =
          const JsonEncoder.withIndent('  ').convert({'appPrefs': appPrefs});
      for (final secret in [
        'app-lock-secret',
        'webdav-secret',
        'dav-secret',
      ]) {
        expect(
          backupJson.contains(secret),
          isFalse,
          reason: '备份明文不得包含敏感值: $secret',
        );
      }
      // 键名层面也不得出现（避免「空值占位」诱导后续误接）
      expect(backupJson.contains(PrefKeys.localPassword), isFalse);
      expect(backupJson.contains('sync_webdav_password'), isFalse);
      expect(
        backupJson.contains('remote_servers'),
        isFalse,
        reason: '新备份不导出远程书库旧偏好（服务器由 servers 段承载）',
      );
    });

    test('恢复远程书库：非敏感字段覆盖，本机密码保留', () async {
      // 备份来自另一台手机：同 id 但 url/username 更新，且（旧版/第三方
      // 备份）携带了明文 password
      await RestoreIgnorePrefs.applyFromBackup(
        {
          'remote_servers': jsonEncode([
            {
              'id': 1,
              'name': '我的网盘（新）',
              'url': 'https://dav2.example/',
              'username': 'alice',
              'password': 'backup-leaked-secret',
            },
            {
              'id': 2,
              'name': '新服务器',
              'url': 'https://dav3.example/',
              'username': 'bob',
              'password': 'backup-leaked-secret-2',
            },
          ]),
        },
        const {},
      );
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('remote_servers')!;
      expect(raw, isNot(contains('backup-leaked-secret')));
      final list = (jsonDecode(raw) as List).cast<Map>();
      expect(list, hasLength(2), reason: '备份列表整体替换本机列表');
      expect(list[0]['name'], '我的网盘（新）');
      expect(list[0]['url'], 'https://dav2.example/');
      expect(
        list[0]['password'],
        'dav-secret',
        reason: '同 id 的本机密码必须保留',
      );
      expect(
        list[1].containsKey('password'),
        isFalse,
        reason: '本机无匹配条目的密码置空（不继承备份明文）',
      );
    });

    test('远程书库净化失败形态：不写入备份也不覆盖本机', () async {
      SharedPreferences.setMockInitialValues({
        'remote_servers': 'not-a-json-array',
      });
      final collected = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(collected.containsKey('remote_servers'), isFalse);

      await RestoreIgnorePrefs.applyFromBackup(
        {'remote_servers': 'still-not-json'},
        const {},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('remote_servers'), 'not-a-json-array');
    });

    // [批17d P3-4] `password` 键名大小写不敏感：本应用恒写小写，但手改 /
    // 第三方产物可能是 Password / PASSWORD——备份侧必须同样剥除，恢复侧
    // 同样不得把它当普通字段写回（仅本应用 schema 的顶层 password）
    test('password 键大小写不敏感剥除（恢复侧合并）', () async {
      final merged = await RestoreIgnorePrefs.mergeRemoteServersFromBackup(
        jsonEncode([
          {
            'id': 1,
            'name': '我的网盘',
            'url': 'https://dav.example/',
            'username': 'alice',
            'Password': 'upper-secret',
            'PASSWORD': 'upper-secret-2',
            'note': '保留',
          },
        ]),
        localPasswordsById: const {},
        localPasswordsByEndpoint: const {},
      );
      expect(merged, isNotNull);
      expect(merged, isNot(contains('upper-secret')), reason: '大写键的口令不得进本机');
      expect(merged!.toLowerCase(), isNot(contains('password')));
      final server = (jsonDecode(merged) as List).first as Map;
      expect(server['id'], 1);
      expect(server['username'], 'alice');
      expect(server['note'], '保留', reason: '仅剥除 password 键，其余字段原样保留');
    });

    test('恢复时密码优先取 servers 表索引（不再依赖旧偏好）', () async {
      // 旧偏好里的密码已过期（批18a 后不再更新）
      SharedPreferences.setMockInitialValues({
        'remote_servers':
            '[{"id":1,"name":"旧","url":"https://old/","username":"u",'
                '"password":"stale-prefs-password"}]',
      });
      final merged = await RestoreIgnorePrefs.mergeRemoteServersFromBackup(
        jsonEncode([
          {
            'id': 1,
            'name': '新',
            'url': 'https://new/',
            'username': 'u2',
            'password': 'backup-leaked-secret',
          },
          {
            'id': 2,
            'name': '按端点匹配',
            'url': 'https://endpoint/',
            'username': 'bob',
          },
        ]),
        localPasswordsById: {1: 'db-password'},
        localPasswordsByEndpoint: {
          'https://endpoint/\u0000bob': 'endpoint-password',
        },
      );

      final list = (jsonDecode(merged!) as List).cast<Map>();
      expect(list[0]['password'], 'db-password',
          reason: '同 id 取 DB 密码，不取过期偏好/备份明文');
      expect(list[1]['password'], 'endpoint-password',
          reason: 'id 不匹配时按 url+username 匹配 DB 密码');
      expect(merged, isNot(contains('backup-leaked-secret')));
      expect(merged, isNot(contains('stale-prefs-password')));
    });

    test('password 键大小写不敏感剥除（恢复侧）', () async {
      // 本机已有同 id 条目（小写 password 为本机密码）
      SharedPreferences.setMockInitialValues({
        'remote_servers': '[{"id":1,"name":"本机网盘","url":"https://dav.example/",'
            '"username":"alice","password":"dav-secret"}]',
      });
      await RestoreIgnorePrefs.applyFromBackup(
        {
          'remote_servers': jsonEncode([
            {
              'id': 1,
              'name': '我的网盘（新）',
              'url': 'https://dav.example/',
              'username': 'alice',
              'Password': 'upper-secret',
            },
            {
              'id': 9,
              'name': '新服务器',
              'url': 'https://dav9.example/',
              'username': 'bob',
              'PASSWORD': 'upper-secret-2',
            },
          ]),
        },
        const {},
      );
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('remote_servers')!;
      expect(raw, isNot(contains('upper-secret')), reason: '备份明文口令不得写回');
      final list = (jsonDecode(raw) as List).cast<Map>();
      expect(list[0]['name'], '我的网盘（新）', reason: '非敏感字段照常覆盖');
      expect(
        list[0]['password'],
        'dav-secret',
        reason: '大写 Password 不影响按 id 取回本机密码',
      );
      expect(
        list[1].keys.map((k) => '$k'.toLowerCase()),
        isNot(contains('password')),
        reason: '本机无匹配条目时不得继承备份明文（含大写键）',
      );
    });
  });
}
