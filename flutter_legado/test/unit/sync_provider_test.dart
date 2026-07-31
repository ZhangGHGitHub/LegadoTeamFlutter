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
    });

    test('初始 isConfigured 为 false', () {
      expect(provider.isConfigured, isFalse);
    });

    test('初始 lastSyncTimeLabel 为"从未同步"', () {
      expect(provider.lastSyncTimeLabel, equals('从未同步'));
    });
  });

  group('SyncProvider 配置管理', () {
    test('saveConfig 保存 WebDAV 配置', () async {
      await provider.saveConfig(
        'https://dav.example.com',
        'user@test.com',
        'pass123',
        '/backup/',
      );

      expect(provider.webDavUrl, equals('https://dav.example.com'));
      expect(provider.webDavUsername, equals('user@test.com'));
      expect(provider.webDavPassword, equals('pass123'));
      expect(provider.remoteDir, equals('/backup/'));
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
      );
      expect(provider.webDavUrl, equals('https://dav.com'));
      expect(provider.webDavUsername, equals('user'));
      expect(provider.remoteDir, equals('/dir/'));
    });

    test('saveConfig 触发通知', () async {
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.saveConfig('url', 'user', 'pass', '/dir/');
      expect(notified, isTrue);
    });

    test('loadConfig 从 SharedPreferences 加载', () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'sync_webdav_url': 'https://loaded.com',
        'sync_webdav_username': 'loaded_user',
        'sync_webdav_password': 'loaded_pass',
        'sync_webdav_remote_dir': '/loaded/',
        'sync_auto': true,
        'sync_last_time': now.millisecondsSinceEpoch,
      });
      final p = SyncProvider(mockApi);
      await p.loadConfig();

      expect(p.webDavUrl, equals('https://loaded.com'));
      expect(p.webDavUsername, equals('loaded_user'));
      expect(p.webDavPassword, equals('loaded_pass'));
      expect(p.remoteDir, equals('/loaded/'));
      expect(p.autoSync, isTrue);
      expect(p.lastSyncTime, isNotNull);
    });

    test('loadConfig 触发通知', () async {
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.loadConfig();
      expect(notified, isTrue);
    });

    test('toggleAutoSync 开启自动同步', () async {
      await provider.toggleAutoSync(true);
      expect(provider.autoSync, isTrue);
    });

    test('toggleAutoSync 关闭自动同步', () async {
      await provider.toggleAutoSync(true);
      await provider.toggleAutoSync(false);
      expect(provider.autoSync, isFalse);
    });

    test('toggleAutoSync 触发通知', () async {
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.toggleAutoSync(true);
      expect(notified, isTrue);
    });
  });

  group('SyncProvider 同步操作（mock API）', () {
    test('syncUpload 未配置时设置错误', () async {
      await provider.syncUpload();
      expect(provider.status, equals(SyncStatus.error));
      expect(provider.error, equals('请先配置 WebDAV 服务器信息'));
    });

    test('syncDownload 未配置时设置错误', () async {
      await provider.syncDownload();
      expect(provider.status, equals(SyncStatus.error));
      expect(provider.error, equals('请先配置 WebDAV 服务器信息'));
    });

    test('syncMerge 未配置时设置错误', () async {
      await provider.syncMerge();
      expect(provider.status, equals(SyncStatus.error));
      expect(provider.error, equals('请先配置 WebDAV 服务器信息'));
    });

    test('syncUpload 配置后成功上传', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => [
            const Book(bookUrl: 'b1', name: '书1'),
          ]);
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await provider.syncUpload();

      expect(provider.status, equals(SyncStatus.success));
      expect(provider.error, isNull);
      expect(provider.lastSyncTime, isNotNull);
    });

    test('syncUpload 失败时设置错误', () async {
      when(() => mockApi.getBooks()).thenThrow(Exception('网络错误'));
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await provider.syncUpload();

      expect(provider.status, equals(SyncStatus.error));
      expect(provider.error, contains('上传失败'));
    });

    test('syncDownload 配置后成功下载', () async {
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await provider.syncDownload();

      expect(provider.status, equals(SyncStatus.success));
      expect(provider.error, isNull);
      expect(provider.lastSyncTime, isNotNull);
    });

    test('syncMerge 配置后成功合并', () async {
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await provider.syncMerge();

      expect(provider.status, equals(SyncStatus.success));
      expect(provider.lastSyncTime, isNotNull);
    });
  });

  group('SyncProvider lastSyncTimeLabel', () {
    test('刚刚同步显示"刚刚"', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);
      await provider.saveConfig('https://dav.com', 'user', 'pass', '/dir/');
      await provider.syncUpload();

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
