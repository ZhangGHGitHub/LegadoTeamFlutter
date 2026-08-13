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
    late MockRustApi mockApi;
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
      mockApi = MockRustApi();
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
      when(() => mockApi.updateBook(any())).thenAnswer((_) async {});

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
    });
  });
}
