import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/providers/sync_provider.dart';
import 'package:flutter_legado/src/models/models.dart';

import '../mocks/mocks.dart';

void main() {
  late SyncProvider provider;
  late MockRustApi mockApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    provider = SyncProvider(mockApi);
  });

  /// 桩入真实同步所需的 BookApi 调用
  void stubSyncApis({String remoteSources = '[]'}) {
    when(() => mockApi.getBooks()).thenAnswer((_) async => [
          const Book(bookUrl: 'b1', name: '书1'),
        ]);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => [
          const BookSource(bookSourceUrl: 'https://a.com', bookSourceName: '源A'),
        ]);
    when(() => mockApi.webdavFullSync(any(), any(), any())).thenAnswer(
      (_) async => '{"books":"[]","sources":$remoteSources}',
    );
    when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 1);
  }

  group('SyncProvider 初始状态', () {
    test('初始状态为 idle', () {
      expect(provider.status, equals(SyncStatus.idle));
    });

    test('初始无最后同步时间', () {
      expect(provider.lastSyncTime, isNull);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });

    test('初始自动同步关闭', () {
      expect(provider.autoSync, isFalse);
    });

    test('初始 WebDAV 配置为空', () {
      expect(provider.webDavUrl, equals(''));
      expect(provider.webDavUsername, equals(''));
      expect(provider.webDavPassword, equals(''));
      expect(provider.remoteDir, equals('/legado/'));
      expect(provider.deviceName, equals(''));
    });

    test('初始同步书籍进度默认开启、增强默认关闭', () {
      expect(provider.syncBookProgress, isTrue);
      expect(provider.syncBookProgressPlus, isFalse);
    });

    test('初始 isConfigured 为 false', () {
      expect(provider.isConfigured, isFalse);
    });

    test('初始 lastSyncTimeLabel 为"从未同步"', () {
      expect(provider.lastSyncTimeLabel, equals('从未同步'));
    });
  });

  group('SyncProvider 配置管理', () {
    test('saveConfig 保存 WebDAV 配置（含设备名）', () async {
      await provider.saveConfig(
        'https://dav.example.com',
        'user@test.com',
        'pass123',
        '/backup/',
        deviceName: 'my-phone',
      );

      expect(provider.webDavUrl, equals('https://dav.example.com'));
      expect(provider.webDavUsername, equals('user@test.com'));
      expect(provider.webDavPassword, equals('pass123'));
      expect(provider.remoteDir, equals('/backup/'));
      expect(provider.deviceName, equals('my-phone'));
      expect(provider.isConfigured, isTrue);
    });

    test('saveConfig 空目录时使用默认 /legado/', () async {
      await provider.saveConfig('https://dav.com', 'user', 'pass', '  ');
      expect(provider.remoteDir, equals('/legado/'));
    });

    test('saveConfig trim 处理', () async {
      await provider.saveConfig(
        '  https://dav.com  ',
        '  user  ',
        'pass',
        '  /dir/  ',
        deviceName: '  dev  ',
      );
      expect(provider.webDavUrl, equals('https://dav.com'));
      expect(provider.webDavUsername, equals('user'));
      expect(provider.remoteDir, equals('/dir/'));
      expect(provider.deviceName, equals('dev'));
    });

    test('saveConfig 触发通知', () async {
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.saveConfig('url', 'user', 'pass', '/dir/');
      expect(notified, isTrue);
    });

    test('buildConfigJson 输出 Rust WebDavConfig 结构', () async {
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');
      expect(
        provider.buildConfigJson(),
        equals('{"url":"https://dav.com","username":"user","password":"pass"}'),
      );
    });

    test('loadConfig 从 SharedPreferences 加载（含新字段）', () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'sync_webdav_url': 'https://loaded.com',
        'sync_webdav_username': 'loaded_user',
        'sync_webdav_password': 'loaded_pass',
        'sync_webdav_remote_dir': '/loaded/',
        'sync_webdav_device_name': 'loaded_dev',
        'sync_book_progress': false,
        'sync_book_progress_plus': true,
        'sync_auto': true,
        'sync_last_time': now.millisecondsSinceEpoch,
      });
      final p = SyncProvider(mockApi);
      await p.loadConfig();

      expect(p.webDavUrl, equals('https://loaded.com'));
      expect(p.webDavUsername, equals('loaded_user'));
      expect(p.webDavPassword, equals('loaded_pass'));
      expect(p.remoteDir, equals('/loaded/'));
      expect(p.deviceName, equals('loaded_dev'));
      expect(p.syncBookProgress, isFalse);
      expect(p.syncBookProgressPlus, isTrue);
      expect(p.autoSync, isTrue);
      expect(p.lastSyncTime, isNotNull);
    });

    test('loadConfig 触发通知', () async {
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.loadConfig();
      expect(notified, isTrue);
    });

    test('toggleAutoSync 开启/关闭自动同步', () async {
      await provider.toggleAutoSync(true);
      expect(provider.autoSync, isTrue);
      await provider.toggleAutoSync(false);
      expect(provider.autoSync, isFalse);
    });

    test('setSyncBookProgress 持久化开关', () async {
      await provider.setSyncBookProgress(false);
      expect(provider.syncBookProgress, isFalse);
    });

    test('setSyncBookProgressPlus 持久化开关', () async {
      await provider.setSyncBookProgressPlus(true);
      expect(provider.syncBookProgressPlus, isTrue);
    });
  });

  group('SyncProvider 真实同步操作', () {
    test('backupToWebDav 未配置时设置错误', () async {
      await provider.backupToWebDav();
      expect(provider.status, equals(SyncStatus.error));
      expect(provider.error, equals('请先配置 WebDAV 服务器信息'));
    });

    test('restoreFromWebDav 未配置时返回提示', () async {
      final msg = await provider.restoreFromWebDav();
      expect(provider.status, equals(SyncStatus.error));
      expect(msg, equals('请先配置 WebDAV 服务器信息'));
    });

    test('backupToWebDav 配置后调用 webdavFullSync 成功', () async {
      stubSyncApis();
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await provider.backupToWebDav();

      expect(provider.status, equals(SyncStatus.success));
      expect(provider.error, isNull);
      expect(provider.lastSyncTime, isNotNull);
      verify(() => mockApi.webdavFullSync(any(), any(), any())).called(1);
    });

    test('backupToWebDav 失败时设置错误', () async {
      when(() => mockApi.getBooks()).thenThrow(Exception('网络错误'));
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await provider.backupToWebDav();

      expect(provider.status, equals(SyncStatus.error));
      expect(provider.error, contains('备份失败'));
    });

    test('restoreFromWebDav 回写远端书源', () async {
      stubSyncApis(remoteSources: '[{"bookSourceUrl":"https://a.com"}]');
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      final msg = await provider.restoreFromWebDav();

      expect(provider.status, equals(SyncStatus.success));
      expect(msg, contains('回写 1 条书源'));
      verify(() => mockApi.importBookSources(any())).called(1);
    });

    test('restoreFromWebDav 远端书源为空时不回写', () async {
      stubSyncApis(remoteSources: '[]');
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      final msg = await provider.restoreFromWebDav();

      expect(provider.status, equals(SyncStatus.success));
      expect(msg, contains('回写 0 条书源'));
      verifyNever(() => mockApi.importBookSources(any()));
    });
  });

  group('SyncProvider lastSyncTimeLabel', () {
    test('刚刚同步显示"刚刚"', () async {
      stubSyncApis();
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');
      await provider.backupToWebDav();

      expect(provider.lastSyncTimeLabel, equals('刚刚'));
    });
  });

  group('SyncStatus 枚举', () {
    test('包含所有预期状态', () {
      expect(SyncStatus.values, containsAll([
        SyncStatus.idle,
        SyncStatus.syncing,
        SyncStatus.success,
        SyncStatus.error,
      ]));
    });
  });
}
