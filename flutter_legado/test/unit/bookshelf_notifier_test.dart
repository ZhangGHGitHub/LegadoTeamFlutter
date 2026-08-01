import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/book_api.dart';

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
    // 创建容器并覆盖 bookApiProvider 注入 mock
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
      ],
    );
    addTearDown(container.dispose);
  });

  /// 等待异步初始化完成
  Future<void> pumpInit() async {
    // build() 中触发了 _loadSettings + _loadBooks 异步操作
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
  }

  BookshelfState readState() => container.read(bookshelfNotifierProvider);
  BookshelfNotifier readNotifier() => container.read(bookshelfNotifierProvider.notifier);

  // ===== 测试数据 =====

  final testBooks = [
    const Book(name: '斗破苍穹', author: '天蚕土豆', bookUrl: 'book://1', originName: '笔趣阁'),
    const Book(name: '完美世界', author: '辰东', bookUrl: 'book://2', originName: '书趣阁'),
    const Book(name: '本地书籍', author: '', bookUrl: 'book://3', originName: ''),
  ];

  group('BookshelfNotifier 初始化', () {
    test('build() 后自动加载书籍', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => testBooks);

      // 触发 Notifier 创建
      container.read(bookshelfNotifierProvider);
      await pumpInit();

      expect(readState().books, hasLength(3));
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
      verify(() => mockApi.getBooks()).called(1);
    });

    test('初始状态：网格视图 + 不分组', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);
      container.read(bookshelfNotifierProvider);
      await pumpInit();

      expect(readState().isGridView, isTrue);
      expect(readState().groupMode, equals(GroupMode.none));
      expect(readState().showRecentReading, isTrue);
      expect(readState().showStats, isTrue);
    });

    test('加载失败时设置 error', () async {
      when(() => mockApi.getBooks()).thenThrow(
        const BridgeError(message: '数据库连接失败'),
      );

      container.read(bookshelfNotifierProvider);
      await pumpInit();

      expect(readState().error, equals('数据库连接失败'));
      expect(readState().isLoading, isFalse);
      expect(readState().books, isEmpty);
    });

    test('非 BridgeError 异常也能正确映射', () async {
      when(() => mockApi.getBooks()).thenThrow(Exception('网络超时'));

      container.read(bookshelfNotifierProvider);
      await pumpInit();

      expect(readState().error, contains('网络超时'));
      expect(readState().isLoading, isFalse);
    });
  });

  group('BookshelfNotifier 书籍操作', () {
    setUp(() {
      when(() => mockApi.getBooks()).thenAnswer((_) async => testBooks);
      container.read(bookshelfNotifierProvider);
    });

    test('refresh 重新加载书籍', () async {
      await pumpInit();
      final newBooks = [const Book(name: '新书', bookUrl: 'book://new')];
      when(() => mockApi.getBooks()).thenAnswer((_) async => newBooks);

      await readNotifier().refresh();

      expect(readState().books, hasLength(1));
      expect(readState().books.first.name, equals('新书'));
    });

    test('addBook 成功后追加到列表', () async {
      await pumpInit();
      const newBook = Book(name: ' added', bookUrl: 'book://added');
      when(() => mockApi.addBook(any())).thenAnswer((_) async => newBook);

      await readNotifier().addBook(newBook);

      expect(readState().books, hasLength(4));
      expect(readState().books.last.name, equals(' added'));
    });

    test('addBook 失败时设置 error', () async {
      await pumpInit();
      when(() => mockApi.addBook(any())).thenThrow(
        const BridgeError(message: '添加失败'),
      );

      await readNotifier().addBook(const Book(name: 'x', bookUrl: 'x'));

      expect(readState().error, equals('添加失败'));
      expect(readState().books, hasLength(3)); // 未变
    });

    test('removeBook 成功后从列表移除', () async {
      await pumpInit();
      when(() => mockApi.deleteBook('book://2')).thenAnswer((_) async {});

      await readNotifier().removeBook('book://2');

      expect(readState().books, hasLength(2));
      expect(readState().books.any((b) => b.bookUrl == 'book://2'), isFalse);
    });

    test('removeBook 失败时设置 error 且列表不变', () async {
      await pumpInit();
      when(() => mockApi.deleteBook(any())).thenThrow(
        const BridgeError(message: '删除失败'),
      );

      await readNotifier().removeBook('book://1');

      expect(readState().error, equals('删除失败'));
      expect(readState().books, hasLength(3));
    });

    test('importLocalBook 成功后更新列表', () async {
      await pumpInit();
      const imported = Book(name: '导入书', bookUrl: 'book://import');
      when(() => mockApi.importLocalBook('/path/to/file.epub'))
          .thenAnswer((_) async => imported);

      final result = await readNotifier().importLocalBook('/path/to/file.epub');

      expect(result.name, equals('导入书'));
      expect(readState().books, hasLength(4));
      expect(readState().books.last.bookUrl, equals('book://import'));
    });

    test('importLocalBook 重复导入时替换旧记录', () async {
      await pumpInit();
      const updated = Book(name: '斗破苍穹(更新)', bookUrl: 'book://1');
      when(() => mockApi.importLocalBook(any()))
          .thenAnswer((_) async => updated);

      await readNotifier().importLocalBook('/path/txt');

      // book://1 被替换而非追加
      expect(readState().books, hasLength(3));
      expect(readState().books.where((b) => b.bookUrl == 'book://1').length, equals(1));
      expect(
        readState().books.firstWhere((b) => b.bookUrl == 'book://1').name,
        equals('斗破苍穹(更新)'),
      );
    });
  });

  group('BookshelfNotifier 展示层状态', () {
    setUp(() {
      when(() => mockApi.getBooks()).thenAnswer((_) async => testBooks);
      container.read(bookshelfNotifierProvider);
    });

    test('toggleViewMode 切换网格/列表', () async {
      await pumpInit();
      expect(readState().isGridView, isTrue);

      readNotifier().toggleViewMode();
      expect(readState().isGridView, isFalse);

      readNotifier().toggleViewMode();
      expect(readState().isGridView, isTrue);
    });

    test('setGroupMode 切换分组模式', () async {
      await pumpInit();
      expect(readState().groupMode, equals(GroupMode.none));

      readNotifier().setGroupMode(GroupMode.bySource);
      expect(readState().groupMode, equals(GroupMode.bySource));

      readNotifier().setGroupMode(GroupMode.byGroup);
      expect(readState().groupMode, equals(GroupMode.byGroup));
    });

    test('clearError 清除错误', () async {
      await pumpInit();
      // 手动制造错误状态
      when(() => mockApi.getBooks()).thenThrow(Exception('err'));
      await readNotifier().refresh();
      expect(readState().error, isNotNull);

      readNotifier().clearError();
      expect(readState().error, isNull);
    });

    test('reorderBook 拖拽排序', () async {
      await pumpInit();
      expect(readState().books[0].name, equals('斗破苍穹'));
      expect(readState().books[1].name, equals('完美世界'));

      // 将第 0 本移到第 2 位
      readNotifier().reorderBook(0, 2);

      expect(readState().books[0].name, equals('完美世界'));
      expect(readState().books[1].name, equals('斗破苍穹'));
      // order 字段已更新
      expect(readState().books[0].order, equals(0));
      expect(readState().books[1].order, equals(1));
    });

    test('reorderBook 越界索引不生效', () async {
      await pumpInit();
      final before = readState().books;

      readNotifier().reorderBook(-1, 0);
      readNotifier().reorderBook(0, 100);

      expect(readState().books, equals(before));
    });
  });

  group('BookshelfNotifier 分组展示', () {
    setUp(() {
      when(() => mockApi.getBooks()).thenAnswer((_) async => testBooks);
      container.read(bookshelfNotifierProvider);
    });

    test('GroupMode.none 返回单一「全部」分组', () async {
      await pumpInit();
      final groups = readState().groupedBooks;

      expect(groups.keys, contains('全部'));
      expect(groups['全部'], hasLength(3));
    });

    test('GroupMode.bySource 按来源分组', () async {
      await pumpInit();
      readNotifier().setGroupMode(GroupMode.bySource);
      final groups = readState().groupedBooks;

      expect(groups.keys, contains('笔趣阁'));
      expect(groups.keys, contains('书趣阁'));
      expect(groups.keys, contains('本地')); // originName 为空时归入「本地」
      expect(groups['笔趣阁'], hasLength(1));
    });

    test('isEmpty 扩展：有书时非空', () async {
      await pumpInit();
      expect(readState().isEmpty, isFalse);
    });

    test('isEmpty 扩展：无书且不在加载时为空', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);
      // 重新创建容器
      container.dispose();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      container.read(bookshelfNotifierProvider);
      await pumpInit();

      expect(readState().isEmpty, isTrue);
    });
  });

  group('BookshelfNotifier 用户偏好', () {
    setUp(() {
      when(() => mockApi.getBooks()).thenAnswer((_) async => testBooks);
      container.read(bookshelfNotifierProvider);
    });

    test('toggleShowRecentReading 切换并持久化', () async {
      await pumpInit();
      expect(readState().showRecentReading, isTrue);

      await readNotifier().toggleShowRecentReading();
      expect(readState().showRecentReading, isFalse);

      // 验证持久化
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bookshelf_show_recent_reading'), isFalse);
    });

    test('toggleShowStats 切换并持久化', () async {
      await pumpInit();
      expect(readState().showStats, isTrue);

      await readNotifier().toggleShowStats();
      expect(readState().showStats, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bookshelf_show_stats'), isFalse);
    });
  });
}
