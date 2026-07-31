import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/providers/bookshelf_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late BookshelfProvider provider;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    provider = BookshelfProvider(mockApi);
  });

  group('BookshelfProvider 初始状态', () {
    test('初始书架为空', () {
      expect(provider.books, isEmpty);
      expect(provider.isEmpty, isTrue);
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('初始视图模式为网格', () {
      expect(provider.isGridView, isTrue);
    });

    test('初始分组模式为 none', () {
      expect(provider.groupMode, equals(GroupMode.none));
    });

    test('初始显示最近阅读和统计', () {
      expect(provider.showRecentReading, isTrue);
      expect(provider.showStats, isTrue);
    });
  });

  group('BookshelfProvider 视图切换', () {
    test('toggleViewMode 切换为列表视图', () {
      provider.toggleViewMode();
      expect(provider.isGridView, isFalse);
    });

    test('toggleViewMode 再次切换回网格视图', () {
      provider.toggleViewMode();
      provider.toggleViewMode();
      expect(provider.isGridView, isTrue);
    });

    test('toggleViewMode 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.toggleViewMode();
      expect(notified, isTrue);
    });
  });

  group('BookshelfProvider 分组模式', () {
    test('setGroupMode 切换到 bySource', () {
      provider.setGroupMode(GroupMode.bySource);
      expect(provider.groupMode, equals(GroupMode.bySource));
    });

    test('setGroupMode 切换到 byGroup', () {
      provider.setGroupMode(GroupMode.byGroup);
      expect(provider.groupMode, equals(GroupMode.byGroup));
    });

    test('setGroupMode 切换回 none', () {
      provider.setGroupMode(GroupMode.bySource);
      provider.setGroupMode(GroupMode.none);
      expect(provider.groupMode, equals(GroupMode.none));
    });

    test('setGroupMode 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.setGroupMode(GroupMode.byGroup);
      expect(notified, isTrue);
    });

    test('空书架时 groupedBooks 返回全部键', () {
      final grouped = provider.groupedBooks;
      expect(grouped.containsKey('全部'), isTrue);
      expect(grouped['全部'], isEmpty);
    });
  });

  group('BookshelfProvider groupedBooks 分组逻辑（mock API）', () {
    final books = [
      const Book(bookUrl: 'b1', name: '书1', originName: '笔趣阁', group: 1),
      const Book(bookUrl: 'b2', name: '书2', originName: '笔趣阁', group: 0),
      const Book(bookUrl: 'b3', name: '书3', originName: '起点', group: 2),
      const Book(bookUrl: 'b4', name: '书4', originName: '', group: 0),
    ];

    setUp(() {
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
    });

    test('GroupMode.none 时 groupedBooks 返回全部', () async {
      await provider.loadBooks();
      provider.setGroupMode(GroupMode.none);
      final grouped = provider.groupedBooks;
      expect(grouped.keys.length, equals(1));
      expect(grouped['全部']!.length, equals(4));
    });

    test('GroupMode.bySource 时按书源名分组', () async {
      await provider.loadBooks();
      provider.setGroupMode(GroupMode.bySource);
      final grouped = provider.groupedBooks;
      expect(grouped.containsKey('笔趣阁'), isTrue);
      expect(grouped['笔趣阁']!.length, equals(2));
      expect(grouped.containsKey('起点'), isTrue);
      expect(grouped['起点']!.length, equals(1));
      // originName 为空时归入"本地"
      expect(grouped.containsKey('本地'), isTrue);
      expect(grouped['本地']!.length, equals(1));
    });

    test('GroupMode.byGroup 时按 group 字段分组', () async {
      await provider.loadBooks();
      provider.setGroupMode(GroupMode.byGroup);
      final grouped = provider.groupedBooks;
      expect(grouped.containsKey('分组 1'), isTrue);
      expect(grouped['分组 1']!.length, equals(1));
      expect(grouped.containsKey('分组 2'), isTrue);
      expect(grouped['分组 2']!.length, equals(1));
      // group=0 归入"默认"
      expect(grouped.containsKey('默认'), isTrue);
      expect(grouped['默认']!.length, equals(2));
    });
  });

  group('BookshelfProvider loadBooks（mock API）', () {
    test('loadBooks 成功加载书籍列表', () async {
      final books = [
        const Book(bookUrl: 'b1', name: '书1'),
        const Book(bookUrl: 'b2', name: '书2'),
      ];
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);

      await provider.loadBooks();

      expect(provider.books.length, equals(2));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
      expect(provider.isEmpty, isFalse);
    });

    test('loadBooks 失败时设置 BridgeError', () async {
      when(() => mockApi.getBooks())
          .thenThrow(const BridgeError(message: '数据库打开失败'));

      await provider.loadBooks();

      expect(provider.error, equals('数据库打开失败'));
      expect(provider.loading, isFalse);
      expect(provider.books, isEmpty);
    });

    test('loadBooks 失败时设置普通异常', () async {
      when(() => mockApi.getBooks()).thenThrow(Exception('未知'));

      await provider.loadBooks();

      expect(provider.error, contains('未知'));
      expect(provider.loading, isFalse);
    });

    test('loadBooks 触发通知（加载中和完成）', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      await provider.loadBooks();
      // 至少触发 2 次：开始加载 + 完成
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('BookshelfProvider addBook（mock API）', () {
    test('addBook 成功添加到列表', () async {
      const book = Book(bookUrl: 'new1', name: '新书');
      when(() => mockApi.addBook(any())).thenAnswer((_) async => book);

      await provider.addBook(book);

      expect(provider.books.length, equals(1));
      expect(provider.books.first.name, equals('新书'));
    });

    test('addBook 失败时设置错误', () async {
      const book = Book(bookUrl: 'new1', name: '新书');
      when(() => mockApi.addBook(any()))
          .thenThrow(const BridgeError(message: '添加失败'));

      await provider.addBook(book);

      expect(provider.error, equals('添加失败'));
      expect(provider.books, isEmpty);
    });
  });

  group('BookshelfProvider removeBook（mock API）', () {
    test('removeBook 成功从列表移除', () async {
      final books = [
        const Book(bookUrl: 'b1', name: '书1'),
        const Book(bookUrl: 'b2', name: '书2'),
      ];
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
      when(() => mockApi.deleteBook(any())).thenAnswer((_) async {});

      await provider.loadBooks();
      await provider.removeBook('b1');

      expect(provider.books.length, equals(1));
      expect(provider.books.first.bookUrl, equals('b2'));
    });

    test('removeBook 失败时设置错误', () async {
      when(() => mockApi.deleteBook(any()))
          .thenThrow(const BridgeError(message: '删除失败'));

      await provider.removeBook('b1');

      expect(provider.error, equals('删除失败'));
    });
  });

  group('BookshelfProvider importLocalBook（mock API）', () {
    test('importLocalBook 成功导入并加入列表', () async {
      const imported = Book(bookUrl: 'local1', name: '本地书.txt');
      when(() => mockApi.importLocalBook(any())).thenAnswer((_) async => imported);

      final result = await provider.importLocalBook('/path/to/book.txt');

      expect(result.name, equals('本地书.txt'));
      expect(provider.books.length, equals(1));
    });

    test('importLocalBook 重复导入时去重', () async {
      const imported = Book(bookUrl: 'local1', name: '本地书.txt');
      when(() => mockApi.importLocalBook(any())).thenAnswer((_) async => imported);

      await provider.importLocalBook('/path/a.txt');
      await provider.importLocalBook('/path/a.txt');

      // 同 bookUrl 只保留一本
      expect(provider.books.length, equals(1));
    });

    test('importLocalBook 失败时异常向上抛出', () async {
      when(() => mockApi.importLocalBook(any()))
          .thenThrow(const BridgeError(message: '文件不存在'));

      expect(
        () => provider.importLocalBook('/bad/path'),
        throwsA(isA<BridgeError>()),
      );
    });
  });

  group('BookshelfProvider reorderBook 排序', () {
    test('空书架时 reorderBook 不抛异常', () {
      provider.reorderBook(0, 1);
      expect(provider.books, isEmpty);
    });

    test('负索引 reorderBook 不抛异常', () {
      provider.reorderBook(-1, 0);
      expect(provider.books, isEmpty);
    });

    test('reorderBook 正确移动书籍位置', () async {
      final books = [
        const Book(bookUrl: 'b1', name: '书1', order: 0),
        const Book(bookUrl: 'b2', name: '书2', order: 1),
        const Book(bookUrl: 'b3', name: '书3', order: 2),
      ];
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
      await provider.loadBooks();

      // 将第 0 本移到第 2 位（newIndex=2 在 ReorderableListView 中表示移到 index 1 之后）
      provider.reorderBook(0, 2);

      expect(provider.books[0].bookUrl, equals('b2'));
      expect(provider.books[1].bookUrl, equals('b1'));
      expect(provider.books[2].bookUrl, equals('b3'));
    });

    test('reorderBook 更新 order 字段', () async {
      final books = [
        const Book(bookUrl: 'b1', name: '书1', order: 0),
        const Book(bookUrl: 'b2', name: '书2', order: 1),
        const Book(bookUrl: 'b3', name: '书3', order: 2),
      ];
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
      await provider.loadBooks();

      provider.reorderBook(2, 0);

      // 验证 order 字段被重新赋值
      for (var i = 0; i < provider.books.length; i++) {
        expect(provider.books[i].order, equals(i));
      }
    });

    test('reorderBook 触发通知', () async {
      final books = [
        const Book(bookUrl: 'b1', name: '书1'),
        const Book(bookUrl: 'b2', name: '书2'),
      ];
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
      await provider.loadBooks();

      var notified = false;
      provider.addListener(() => notified = true);
      provider.reorderBook(0, 1);
      expect(notified, isTrue);
    });

    test('reorderBook newIndex 越界不执行', () async {
      final books = [
        const Book(bookUrl: 'b1', name: '书1'),
        const Book(bookUrl: 'b2', name: '书2'),
      ];
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
      await provider.loadBooks();

      provider.reorderBook(0, 99);
      // 顺序不变
      expect(provider.books[0].bookUrl, equals('b1'));
    });
  });

  group('BookshelfProvider 错误管理', () {
    test('clearError 清除错误状态', () {
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('clearError 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearError();
      expect(notified, isTrue);
    });
  });

  group('BookshelfProvider 偏好设置（SharedPreferences）', () {
    test('toggleShowRecentReading 切换并持久化', () async {
      SharedPreferences.setMockInitialValues({
        'bookshelf_show_recent_reading': true,
      });
      final p = BookshelfProvider(mockApi);
      await p.loadSettings();
      expect(p.showRecentReading, isTrue);

      await p.toggleShowRecentReading();
      expect(p.showRecentReading, isFalse);
    });

    test('toggleShowStats 切换并持久化', () async {
      SharedPreferences.setMockInitialValues({
        'bookshelf_show_stats': true,
      });
      final p = BookshelfProvider(mockApi);
      await p.loadSettings();
      expect(p.showStats, isTrue);

      await p.toggleShowStats();
      expect(p.showStats, isFalse);
    });

    test('loadSettings 从 SharedPreferences 加载偏好', () async {
      SharedPreferences.setMockInitialValues({
        'bookshelf_show_recent_reading': false,
        'bookshelf_show_stats': false,
      });
      final p = BookshelfProvider(mockApi);
      await p.loadSettings();
      expect(p.showRecentReading, isFalse);
      expect(p.showStats, isFalse);
    });
  });
}
