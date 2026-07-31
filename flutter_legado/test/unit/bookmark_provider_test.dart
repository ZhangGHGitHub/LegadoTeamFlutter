/// BookmarkProvider 单元测试
///
/// 覆盖：loadAll/loadByBook/addBookmark/deleteBookmark/search
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/bookmark_provider.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late BookmarkProvider provider;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    provider = BookmarkProvider(mockApi);
  });

  group('BookmarkProvider 初始状态', () {
    test('初始书签列表为空', () {
      expect(provider.bookmarks, isEmpty);
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });
  });

  group('BookmarkProvider loadAll', () {
    test('成功加载所有书签', () async {
      final bookmarks = [
        const Bookmark(id: 1, bookName: '书1', chapterName: '第1章'),
        const Bookmark(id: 2, bookName: '书2', chapterName: '第5章'),
      ];
      when(() => mockApi.getAllBookmarks()).thenAnswer((_) async => bookmarks);

      await provider.loadAll();

      expect(provider.bookmarks.length, equals(2));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('加载失败设置 BridgeError', () async {
      when(() => mockApi.getAllBookmarks())
          .thenThrow(const BridgeError(message: '书签加载失败'));

      await provider.loadAll();

      expect(provider.error, equals('书签加载失败'));
      expect(provider.loading, isFalse);
    });

    test('加载失败设置普通异常', () async {
      when(() => mockApi.getAllBookmarks()).thenThrow(Exception('网络'));

      await provider.loadAll();

      expect(provider.error, contains('网络'));
    });

    test('loadAll 触发通知', () async {
      when(() => mockApi.getAllBookmarks()).thenAnswer((_) async => []);
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      await provider.loadAll();

      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('BookmarkProvider loadByBook', () {
    test('按书名加载书签', () async {
      final bookmarks = [
        const Bookmark(id: 1, bookName: '斗破苍穹', chapterName: '第1章'),
      ];
      when(() => mockApi.getBookmarks(any())).thenAnswer((_) async => bookmarks);

      await provider.loadByBook('斗破苍穹');

      expect(provider.bookmarks.length, equals(1));
      expect(provider.bookmarks[0].bookName, equals('斗破苍穹'));
    });

    test('按书名加载失败设置错误', () async {
      when(() => mockApi.getBookmarks(any()))
          .thenThrow(const BridgeError(message: '查询失败'));

      await provider.loadByBook('不存在的书');

      expect(provider.error, equals('查询失败'));
    });
  });

  group('BookmarkProvider addBookmark', () {
    test('添加书签成功插入列表头部', () async {
      // 先加载一个书签
      when(() => mockApi.getAllBookmarks()).thenAnswer((_) async => [
            const Bookmark(id: 1, bookName: '旧书'),
          ]);
      await provider.loadAll();

      final newBookmark = const Bookmark(
        id: 2,
        bookName: '新书',
        bookAuthor: '作者',
        chapterIndex: 5,
        chapterPos: 100,
        chapterName: '第5章',
        bookText: '一些文本',
        content: '备注',
      );
      when(() => mockApi.addBookmark(any())).thenAnswer((_) async => newBookmark);

      final result = await provider.addBookmark(
        bookName: '新书',
        bookAuthor: '作者',
        chapterIndex: 5,
        chapterPos: 100,
        chapterName: '第5章',
        bookText: '一些文本',
        content: '备注',
      );

      expect(result.id, equals(2));
      expect(provider.bookmarks.length, equals(2));
      // 新书签在头部
      expect(provider.bookmarks[0].bookName, equals('新书'));
    });
  });

  group('BookmarkProvider deleteBookmark', () {
    test('删除书签成功移除', () async {
      when(() => mockApi.getAllBookmarks()).thenAnswer((_) async => [
            const Bookmark(id: 1, bookName: '书1'),
            const Bookmark(id: 2, bookName: '书2'),
          ]);
      await provider.loadAll();

      when(() => mockApi.deleteBookmark(any())).thenAnswer((_) async {});

      await provider.deleteBookmark(1);

      expect(provider.bookmarks.length, equals(1));
      expect(provider.bookmarks[0].id, equals(2));
    });
  });

  group('BookmarkProvider search', () {
    test('关键字搜索', () async {
      final results = [
        const Bookmark(id: 1, bookName: '搜索目标', chapterName: '第1章'),
      ];
      when(() => mockApi.searchBookmarks(any())).thenAnswer((_) async => results);

      await provider.search('目标');

      expect(provider.bookmarks.length, equals(1));
      expect(provider.loading, isFalse);
    });

    test('空关键字调用 loadAll', () async {
      when(() => mockApi.getAllBookmarks()).thenAnswer((_) async => [
            const Bookmark(id: 1, bookName: '全部'),
          ]);

      await provider.search('');

      expect(provider.bookmarks.length, equals(1));
      verify(() => mockApi.getAllBookmarks()).called(1);
    });

    test('搜索失败设置错误', () async {
      when(() => mockApi.searchBookmarks(any()))
          .thenThrow(const BridgeError(message: '搜索出错'));

      await provider.search('test');

      expect(provider.error, equals('搜索出错'));
    });
  });
}
