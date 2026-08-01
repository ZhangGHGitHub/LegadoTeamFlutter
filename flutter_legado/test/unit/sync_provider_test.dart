// SyncNotifier 单元测试
//
// 覆盖 Phase 5.4 provider→Riverpod 迁移后的 WebDAV 云同步状态管理：
// 初始状态/配置管理（saveConfig/loadConfig/toggle/setter）/真实同步操作
// （backupToWebDav/restoreFromWebDav）/lastSyncTimeLabel/SyncStatus 枚举。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/sync/sync_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/models/models.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  SyncState readState() => container.read(syncNotifierProvider);
  SyncNotifier readNotifier() =>
      container.read(syncNotifierProvider.notifier);

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

  group('SyncNotifier 初始状态', () {
    test('初始状态为 idle', () {
      expect(readState().status, equals(SyncStatus.idle));
    });

    test('初始无最后同步时间', () {
      expect(readState().lastSyncTime, isNull);
    });

    test('初始无错误', () {
      expect(readState().error, isNull);
    });

    test('初始自动同步关闭', () {
      expect(readState().autoSync, isFalse);
    });

    test('初始 WebDAV 配置为空', () {
      final state = readState();
      expect(state.webDavUrl, equals(''));
      expect(state.webDavUsername, equals(''));
      expect(state.webDavPassword, equals(''));
      expect(state.remoteDir, equals('/legado/'));
      expect(state.deviceName, equals(''));
    });

    test('初始同步书籍进度默认开启、增强默认关闭', () {
      expect(readState().syncBookProgress, isTrue);
      expect(readState().syncBookProgressPlus, isFalse);
    });

    test('初始 isConfigured 为 false', () {
      expect(readState().isConfigured, isFalse);
    });

    test('初始 lastSyncTimeLabel 为"从未同步"', () {
      expect(readState().lastSyncTimeLabel, equals('从未同步'));
    });
  });

  group('SyncNotifier 配置管理', () {
    test('saveConfig 保存 WebDAV 配置（含设备名）', () async {
      await readNotifier().saveConfig(
        'https://dav.example.com',
        'user@test.com',
        'pass123',
        '/backup/',
        deviceName: 'my-phone',
      );

      final state = readState();
      expect(state.webDavUrl, equals('https://dav.example.com'));
      expect(state.webDavUsername, equals('user@test.com'));
      expect(state.webDavPassword, equals('pass123'));
      expect(state.remoteDir, equals('/backup/'));
      expect(state.deviceName, equals('my-phone'));
      expect(state.isConfigured, isTrue);
    });

    test('saveConfig 空目录时使用默认 /legado/', () async {
      await readNotifier().saveConfig('https://dav.com', 'user', 'pass', '  ');
      expect(readState().remoteDir, equals('/legado/'));
    });

    test('saveConfig trim 处理', () async {
      await readNotifier().saveConfig(
        '  https://dav.com  ',
        '  user  ',
        'pass',
        '  /dir/  ',
        deviceName: '  dev  ',
      );
      final state = readState();
      expect(state.webDavUrl, equals('https://dav.com'));
      expect(state.webDavUsername, equals('user'));
      expect(state.remoteDir, equals('/dir/'));
      expect(state.deviceName, equals('dev'));
    });

    test('saveConfig 触发状态变更通知', () async {
      var notified = false;
      container.listen(syncNotifierProvider, (_, __) => notified = true);
      await readNotifier().saveConfig('url', 'user', 'pass', '/dir/');
      expect(notified, isTrue);
    });

    test('buildConfigJson 输出 Rust WebDavConfig 结构', () async {
      await readNotifier().saveConfig('https://dav.com', 'user', 'pass', '/dir/');
      expect(
        readNotifier().buildConfigJson(),
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
      await readNotifier().loadConfig();

      final state = readState();
      expect(state.webDavUrl, equals('https://loaded.com'));
      expect(state.webDavUsername, equals('loaded_user'));
      expect(state.webDavPassword, equals('loaded_pass'));
      expect(state.remoteDir, equals('/loaded/'));
      expect(state.deviceName, equals('loaded_dev'));
      expect(state.syncBookProgress, isFalse);
      expect(state.syncBookProgressPlus, isTrue);
      expect(state.autoSync, isTrue);
      expect(state.lastSyncTime, isNotNull);
    });

    test('loadConfig 触发状态变更通知', () async {
      var notified = false;
      container.listen(syncNotifierProvider, (_, __) => notified = true);
      await readNotifier().loadConfig();
      expect(notified, isTrue);
    });

    test('toggleAutoSync 开启/关闭自动同步', () async {
      await readNotifier().toggleAutoSync(true);
      expect(readState().autoSync, isTrue);
      await readNotifier().toggleAutoSync(false);
      expect(readState().autoSync, isFalse);
    });

    test('setSyncBookProgress 持久化开关', () async {
      await readNotifier().setSyncBookProgress(false);
      expect(readState().syncBookProgress, isFalse);
    });

    test('setSyncBookProgressPlus 持久化开关', () async {
      await readNotifier().setSyncBookProgressPlus(true);
      expect(readState().syncBookProgressPlus, isTrue);
    });
  });

  group('SyncNotifier 真实同步操作', () {
    test('backupToWebDav 未配置时设置错误', () async {
      await readNotifier().backupToWebDav();
      expect(readState().status, equals(SyncStatus.error));
      expect(readState().error, equals('请先配置 WebDAV 服务器信息'));
    });

    test('restoreFromWebDav 未配置时返回提示', () async {
      final msg = await readNotifier().restoreFromWebDav();
      expect(readState().status, equals(SyncStatus.error));
      expect(msg, equals('请先配置 WebDAV 服务器信息'));
    });

    test('backupToWebDav 配置后调用 webdavFullSync 成功', () async {
      stubSyncApis();
      await readNotifier().saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await readNotifier().backupToWebDav();

      final state = readState();
      expect(state.status, equals(SyncStatus.success));
      expect(state.error, isNull);
      expect(state.lastSyncTime, isNotNull);
      verify(() => mockApi.webdavFullSync(any(), any(), any())).called(1);
    });

    test('backupToWebDav 失败时设置错误', () async {
      when(() => mockApi.getBooks()).thenThrow(Exception('网络错误'));
      await readNotifier().saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      await readNotifier().backupToWebDav();

      expect(readState().status, equals(SyncStatus.error));
      expect(readState().error, contains('备份失败'));
    });

    test('restoreFromWebDav 回写远端书源', () async {
      stubSyncApis(remoteSources: '[{"bookSourceUrl":"https://a.com"}]');
      await readNotifier().saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      final msg = await readNotifier().restoreFromWebDav();

      expect(readState().status, equals(SyncStatus.success));
      expect(msg, contains('回写 1 条书源'));
      verify(() => mockApi.importBookSources(any())).called(1);
    });

    test('restoreFromWebDav 远端书源为空时不回写', () async {
      stubSyncApis(remoteSources: '[]');
      await readNotifier().saveConfig('https://dav.com', 'user', 'pass', '/dir/');

      final msg = await readNotifier().restoreFromWebDav();

      expect(readState().status, equals(SyncStatus.success));
      expect(msg, contains('回写 0 条书源'));
      verifyNever(() => mockApi.importBookSources(any()));
    });
  });

  group('SyncNotifier lastSyncTimeLabel', () {
    test('刚刚同步显示"刚刚"', () async {
      stubSyncApis();
      await readNotifier().saveConfig('https://dav.com', 'user', 'pass', '/dir/');
      await readNotifier().backupToWebDav();

      expect(readState().lastSyncTimeLabel, equals('刚刚'));
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
