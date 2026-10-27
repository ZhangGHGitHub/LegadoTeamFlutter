import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/remote_book/remote_book_notifier.dart';
import 'package:flutter_legado/src/providers/sync/sync_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteBookState path helpers', () {
    test('默认服务器 displayPath / listPath', () {
      const state = RemoteBookState(serverId: -1);
      expect(state.displayPath, 'books/');
      expect(state.listPath, 'books/');
    });

    test('进入子目录后拼接路径', () {
      const state = RemoteBookState(
        serverId: -1,
        dirStack: [
          RemoteBookItem(
            filename: 'novels',
            relativePath: 'books/novels/',
            isDir: true,
          ),
        ],
      );
      expect(state.displayPath, 'books/novels/');
      expect(state.listPath, 'books/novels/');
    });

    test('筛选与排序：目录置顶', () {
      const state = RemoteBookState(
        items: [
          RemoteBookItem(filename: 'b.txt', relativePath: 'books/b.txt'),
          RemoteBookItem(
            filename: 'a_dir',
            relativePath: 'books/a_dir/',
            isDir: true,
          ),
          RemoteBookItem(filename: 'a.txt', relativePath: 'books/a.txt'),
        ],
        sortKey: RemoteBookSort.name,
        sortAscending: true,
      );
      final names = state.visibleItems.map((e) => e.filename).toList();
      expect(names.first, 'a_dir');
      expect(names.sublist(1), ['a.txt', 'b.txt']);
    });
  });

  group('RemoteBookNotifier.refresh / import', () {
    late FakeServersRustApi mockApi;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'sync_webdav_url': 'https://dav.example.com/',
        'sync_webdav_username': 'u',
        'sync_webdav_password': 'p',
        'sync_webdav_remote_dir': '/legado/',
        'remote_server_id': -1,
        'remote_servers': '[]',
      });
      mockApi = FakeServersRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    RemoteBookNotifier readNotifier() =>
        container.read(remoteBookNotifierProvider.notifier);
    RemoteBookState readState() => container.read(remoteBookNotifierProvider);

    test('refresh 解析目录并过滤非书籍文件', () async {
      when(() => mockApi.webdavListDir(any(), any())).thenAnswer(
        (_) async => jsonEncode([
          {
            'name': 'novel.epub',
            'path': '/legado/books/novel.epub',
            'size': 12,
            'is_dir': false,
          },
          {
            'name': 'readme.md',
            'path': '/legado/books/readme.md',
            'size': 1,
            'is_dir': false,
          },
          {
            'name': 'folder',
            'path': '/legado/books/folder/',
            'size': 0,
            'is_dir': true,
          },
        ]),
      );
      when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);

      await container.read(syncNotifierProvider.notifier).loadConfig();
      await readNotifier().init();

      final items = readState().items;
      expect(items.map((e) => e.filename).toSet(), {'novel.epub', 'folder'});
      verify(() => mockApi.webdavListDir(any(), 'books/')).called(1);
    });

    test('addSelectedToBookshelf 下载并 importLocalBook', () async {
      when(() => mockApi.webdavListDir(any(), any()))
          .thenAnswer((_) async => jsonEncode([]));
      when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
      when(() => mockApi.webdavDownloadFile(any(), any(), any()))
          .thenAnswer((_) async {});
      when(() => mockApi.importLocalBook(any())).thenAnswer(
        (_) async => const Book(
          bookUrl: '/tmp/novel.epub',
          name: 'novel',
          origin: 'loc:',
          originName: 'novel.epub',
        ),
      );
      final updated = <Book>[];
      when(() => mockApi.updateBook(any())).thenAnswer((invocation) async {
        updated.add(invocation.positionalArguments.first as Book);
      });

      await container.read(syncNotifierProvider.notifier).loadConfig();
      await readNotifier().init();

      // 注入可选中条目
      container.read(remoteBookNotifierProvider.notifier);
      final n = readNotifier();
      // 直接改 state 较难；通过 refresh 数据再选
      when(() => mockApi.webdavListDir(any(), any())).thenAnswer(
        (_) async => jsonEncode([
          {
            'name': 'novel.epub',
            'path': '/legado/books/novel.epub',
            'size': 12,
            'is_dir': false,
          },
        ]),
      );
      await n.refresh();
      final item = readState().items.single;
      n.toggleSelect(item);
      await n.addSelectedToBookshelf();

      expect(readState().importedCount, 1);
      verify(() => mockApi.webdavDownloadFile(any(), 'books/novel.epub', any()))
          .called(1);
      verify(() => mockApi.importLocalBook(any())).called(1);
      verify(() => mockApi.updateBook(any())).called(1);

      // 批18b：默认服务器 origin 对齐原版 —— webDav:: + 完整远程 URL，
      // serverID=null 不追加属性（RemoteBookViewModel.kt:141-143）
      expect(
        updated.single.origin,
        'webDav::https://dav.example.com/legado/books/novel.epub',
      );
      expect(updated.single.originName, 'novel.epub');
    });

    test('自定义服务器导入 origin 带完整 URL + serverID 属性后缀', () async {
      mockApi.seedServer(
        id: 11,
        name: '自定义网盘',
        config: jsonEncode({
          'url': 'https://dav11.example.com/root/',
          'username': 'u11',
          'password': 'p11',
        }),
      );
      await SharedPreferences.getInstance()
          .then((p) => p.setInt('remote_server_id', 11));

      when(() => mockApi.webdavListDir(any(), any())).thenAnswer(
        (_) async => jsonEncode([
          {
            'name': 'novel.epub',
            'path': '/root/novel.epub',
            'size': 12,
            'is_dir': false,
          },
        ]),
      );
      when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
      when(() => mockApi.webdavDownloadFile(any(), any(), any()))
          .thenAnswer((_) async {});
      when(() => mockApi.importLocalBook(any())).thenAnswer(
        (_) async => const Book(
          bookUrl: '/tmp/novel.epub',
          name: 'novel',
          origin: 'loc_book',
          originName: 'novel.epub',
        ),
      );
      final updated = <Book>[];
      when(() => mockApi.updateBook(any())).thenAnswer((invocation) async {
        updated.add(invocation.positionalArguments.first as Book);
      });

      final n = readNotifier();
      await n.init();
      expect(readState().serverId, 11);

      final item = readState().items.single;
      n.toggleSelect(item);
      await n.addSelectedToBookshelf();

      // 自定义服务器：服务器 url + 相对路径，追加 ,{"serverID":11}
      expect(
        updated.single.origin,
        'webDav::https://dav11.example.com/root/novel.epub,{"serverID":11}',
      );
    });

    test('同名子目录不被隐藏（books/books/）', () async {
      // Rust 侧已过滤 PROPFIND 的自身项；Dart 侧不得再用「名称等于当前目录」
      // 启发式，否则合法的同名子目录（books/books/）会被误隐藏。
      when(() => mockApi.webdavListDir(any(), any())).thenAnswer((inv) async {
        final path = inv.positionalArguments[1] as String;
        // 根目录列出 books/books/，进入后再列出 books/books/books/
        final isRoot = path == 'books/';
        return jsonEncode([
          {
            'name': 'books',
            'path': isRoot ? '/legado/books/books/' : '/legado/books/books/books/',
            'size': 0,
            'is_dir': true,
          },
        ]);
      });
      when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);

      await container.read(syncNotifierProvider.notifier).loadConfig();
      final n = readNotifier();
      await n.init();
      expect(
        readState().items.map((e) => e.filename).toList(),
        ['books'],
        reason: '根目录下与 books 同名的合法子目录不应被隐藏',
      );

      // 进入该目录后仍应看到同名（孙）目录
      n.openDir(readState().items.single);
      await n.refresh();
      expect(
        readState().items.map((e) => e.filename).toList(),
        ['books'],
        reason: '与父目录同名的合法子目录不得被启发式隐藏',
      );
    });

    test('on-shelf 判定兼容新 webDav:: 与存量 dav: 双前缀', () async {      when(() => mockApi.webdavListDir(any(), any())).thenAnswer(
        (_) async => jsonEncode([
          {
            'name': 'legacy.epub',
            'path': '/legado/books/legacy.epub',
            'size': 1,
            'is_dir': false,
          },
          {
            'name': 'newfmt.epub',
            'path': '/legado/books/newfmt.epub',
            'size': 1,
            'is_dir': false,
          },
        ]),
      );
      when(() => mockApi.getBooks()).thenAnswer(
        (_) async => const [
          // 存量格式（批18b 前本仓库写入）
          Book(
            bookUrl: '/tmp/legacy.epub',
            name: 'legacy',
            origin: 'dav:https://dav.example.com/legado/books/legacy.epub',
            originName: 'legacy.epub',
          ),
          // 原版/参考版格式（带 serverID 属性后缀）
          Book(
            bookUrl: '/tmp/newfmt.epub',
            name: 'newfmt',
            origin:
                'webDav::https://dav.example.com/legado/books/newfmt.epub,{"serverID":12}',
            originName: 'newfmt.epub',
          ),
        ],
      );

      await container.read(syncNotifierProvider.notifier).loadConfig();
      await readNotifier().init();

      final items = readState().items;
      expect(items, hasLength(2));
      expect(items.every((e) => e.isOnBookShelf), isTrue);
    });
  });

  // ─── 批18a：服务器列表数据源切换到 servers 表 ─────────────────────────
  group('RemoteBookNotifier 服务器列表（servers 表）', () {
    late FakeServersRustApi mockApi;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'sync_webdav_url': 'https://dav.example.com/',
        'sync_webdav_username': 'u',
        'sync_webdav_password': 'p',
        'sync_webdav_remote_dir': '/legado/',
        'remote_server_id': -1,
      });
      mockApi = FakeServersRustApi();
      when(() => mockApi.webdavListDir(any(), any()))
          .thenAnswer((_) async => jsonEncode([]));
      when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    RemoteBookNotifier readNotifier() =>
        container.read(remoteBookNotifierProvider.notifier);
    RemoteBookState readState() => container.read(remoteBookNotifierProvider);

    test('列表来自 DB 并过滤所有负 id（默认 WebDAV 不在本页展示）', () async {
      mockApi.seedServer(
        id: -1,
        name: '默认 WebDAV',
        config: jsonEncode({
          'url': 'https://dav.example.com/',
          'username': 'u',
          'password': 'p',
        }),
      );
      mockApi.seedServer(
        id: -2,
        name: '历史负 id',
        config: jsonEncode({
          'url': 'https://neg.example.com/',
          'username': 'u',
          'password': 'p',
        }),
      );
      mockApi.seedServer(
        id: 11,
        name: '自定义网盘',
        config: jsonEncode({
          'url': 'https://dav11.example.com/',
          'username': 'u11',
          'password': 'p11',
        }),
      );

      await readNotifier().init();

      expect(readState().servers.map((e) => e.id), [11]);
      expect(readState().servers.single.name, '自定义网盘');
    });

    test('选中 id 在列表不存在时回退默认 WebDAV（不再报配置无效）', () async {
      await SharedPreferences.getInstance()
          .then((p) => p.setInt('remote_server_id', 999));

      await readNotifier().init();

      expect(readState().error, isNull);
      verify(() => mockApi.webdavListDir(any(), 'books/')).called(1);
    });

    test('选中行 config 无效时回退默认 WebDAV', () async {
      mockApi.seedServer(id: 12, name: '坏配置', config: 'not-json');
      await SharedPreferences.getInstance()
          .then((p) => p.setInt('remote_server_id', 12));

      await readNotifier().init();

      expect(readState().error, isNull);
      verify(() => mockApi.webdavListDir(any(), 'books/')).called(1);
    });

    test('新建/编辑/删除均走 servers 表', () async {
      await readNotifier().init();
      expect(readState().servers, isEmpty);

      final created = await readNotifier().saveServer(
        const RemoteServerConfig(
          id: 0,
          name: '新建网盘',
          url: 'https://new.example.com/',
          username: 'u',
          password: 'p',
        ),
      );
      expect(created, isTrue);
      final added = readState().servers.single;
      expect(added.id, greaterThan(0));
      expect(added.name, '新建网盘');

      final edited = await readNotifier().saveServer(
        added.copyWith(name: '改名网盘', url: 'https://edited.example.com/'),
      );
      expect(edited, isTrue);
      final afterEdit = readState().servers.single;
      expect(afterEdit.id, added.id);
      expect(afterEdit.name, '改名网盘');
      expect(afterEdit.url, 'https://edited.example.com/');

      final deleted = await readNotifier().deleteServer(added.id);
      expect(deleted, isTrue);
      expect(readState().servers, isEmpty);
    });

    test('编辑保留既有 sortNumber', () async {
      mockApi.seedServer(
        id: 21,
        name: '旧名',
        config: jsonEncode({'url': 'https://old/', 'username': '', 'password': ''}),
        sortNumber: 6,
      );
      await readNotifier().init();
      expect(readState().servers.single.sortNumber, 6);

      await readNotifier().saveServer(
        readState().servers.single.copyWith(name: '新名'),
      );

      expect(readState().servers.single.sortNumber, 6);
    });

    test('删除当前选中服务器后回退默认并持久化', () async {
      mockApi.seedServer(
        id: 21,
        name: '当前',
        config: jsonEncode({'url': 'https://cur/', 'username': '', 'password': ''}),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('remote_server_id', 21);
      await readNotifier().init();
      expect(readState().serverId, 21);

      expect(await readNotifier().deleteServer(21), isTrue);

      expect(readState().serverId, -1);
      expect(prefs.getInt('remote_server_id'), -1);
    });

    test('DB 读取异常进入错误态（不抛给调用方）', () async {
      final broken = MockRustApi();
      when(() => broken.webdavServersList())
          .thenThrow(StateError('数据库不可用'));
      final brokenContainer = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(broken)],
      );
      addTearDown(brokenContainer.dispose);

      await brokenContainer.read(remoteBookNotifierProvider.notifier).init();

      final state = brokenContainer.read(remoteBookNotifierProvider);
      expect(state.servers, isEmpty);
      expect(state.error, contains('数据库不可用'));
    });

    test('保存失败返回 false 并写入 serverError（Sheet 内联展示）', () async {
      final failing = MockRustApi();
      when(() => failing.webdavServersList()).thenAnswer((_) async => '[]');
      when(() => failing.webdavServerSave(any()))
          .thenThrow(StateError('写入失败'));
      when(() => failing.webdavListDir(any(), any()))
          .thenAnswer((_) async => jsonEncode([]));
      when(() => failing.getBooks()).thenAnswer((_) async => <Book>[]);
      final failContainer = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(failing)],
      );
      addTearDown(failContainer.dispose);

      final notifier = failContainer.read(remoteBookNotifierProvider.notifier);
      await notifier.init();
      // 注：该 fixture 的 webdavServerSave 一律抛错，同步账号迁移会在
      // init 阶段先写入页面级 error；此处只关心服务器操作不改变它
      final errorBefore = failContainer.read(remoteBookNotifierProvider).error;
      final ok = await notifier.saveServer(
        const RemoteServerConfig(
          id: 0,
          name: '新',
          url: 'https://new/',
        ),
      );

      expect(ok, isFalse);
      expect(
        failContainer.read(remoteBookNotifierProvider).serverError,
        contains('写入失败'),
      );
      expect(
        failContainer.read(remoteBookNotifierProvider).error,
        errorBefore,
        reason: '服务器操作错误不得污染页面级 error',
      );
    });

    test('删除未命中（FFI 返回 false）提示不存在并返回 false', () async {
      final api = MockRustApi();
      when(() => api.webdavServersList()).thenAnswer((_) async => '[]');
      when(() => api.webdavServerDelete(any())).thenAnswer((_) async => false);
      when(() => api.webdavListDir(any(), any()))
          .thenAnswer((_) async => jsonEncode([]));
      when(() => api.getBooks()).thenAnswer((_) async => <Book>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(remoteBookNotifierProvider.notifier);
      await notifier.init();

      expect(await notifier.deleteServer(999), isFalse);
      expect(
        container.read(remoteBookNotifierProvider).serverError,
        '服务器不存在或已被删除',
      );
    });
  });
}
