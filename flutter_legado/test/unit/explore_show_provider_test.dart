/// ExploreShowProvider 单元测试
///
/// 覆盖：initData/fetchBooks/refresh/loadMore/去重逻辑/title
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/explore_show_provider.dart';
import 'package:flutter_legado/src/models/models.dart';

import '../mocks/mocks.dart';

void main() {
  late ExploreShowProvider provider;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    provider = ExploreShowProvider(mockApi);
  });

  // 辅助：构造 BookSource
  final testSource = const BookSource(
    bookSourceUrl: 'http://source.com',
    bookSourceName: '测试书源',
  );

  // 辅助：构造 SearchBook 列表
  List<SearchBook> makeBooks(int count, {int startId = 1}) {
    return List.generate(
      count,
      (i) => SearchBook(
        bookUrl: 'http://book.com/${startId + i}',
        name: '书籍${startId + i}',
        author: '作者${startId + i}',
      ),
    );
  }

  group('ExploreShowProvider 初始状态', () {
    test('初始无书源', () {
      expect(provider.source, isNull);
    });

    test('初始分类名为空', () {
      expect(provider.categoryName, equals(''));
    });

    test('初始分类 URL 为空', () {
      expect(provider.categoryUrl, equals(''));
    });

    test('初始书籍列表为空', () {
      expect(provider.books, isEmpty);
    });

    test('初始页码为 1', () {
      expect(provider.page, equals(1));
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
    });

    test('初始 hasMore 为 true', () {
      expect(provider.hasMore, isTrue);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });

    test('初始 title 为空分类名', () {
      expect(provider.title, equals(''));
    });
  });

  group('ExploreShowProvider initData', () {
    test('初始化设置书源和分类信息', () {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      provider.initData(
        source: testSource,
        categoryName: '玄幻',
        categoryUrl: 'http://source.com/xuanhuan',
      );

      expect(provider.source, equals(testSource));
      expect(provider.categoryName, equals('玄幻'));
      expect(provider.categoryUrl, equals('http://source.com/xuanhuan'));
      expect(provider.page, equals(1));
      expect(provider.hasMore, isTrue);
    });

    test('title 显示分类名 - 书源名', () {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      provider.initData(
        source: testSource,
        categoryName: '仙侠',
        categoryUrl: 'http://source.com/xianxia',
      );

      expect(provider.title, equals('仙侠 - 测试书源'));
    });

    test('initData 触发首次 fetchBooks', () async {
      final books = makeBooks(3);
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => books);

      provider.initData(
        source: testSource,
        categoryName: '科幻',
        categoryUrl: 'http://source.com/kehuan',
      );

      // 等待异步 fetchBooks 完成
      await Future.delayed(Duration.zero);

      expect(provider.books.length, equals(3));
    });
  });

  group('ExploreShowProvider fetchBooks', () {
    test('成功加载书籍并递增页码', () async {
      final books = makeBooks(5);
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => books);

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );
      await Future.delayed(Duration.zero);

      expect(provider.books.length, equals(5));
      expect(provider.page, equals(2));
      expect(provider.hasMore, isTrue);
      expect(provider.loading, isFalse);
    });

    test('返回空列表时 hasMore 设为 false', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );
      await Future.delayed(Duration.zero);

      expect(provider.hasMore, isFalse);
    });

    test('去重逻辑：相同 bookUrl 不重复添加', () async {
      // 第一次返回 3 本
      final books1 = makeBooks(3, startId: 1);
      // 第二次返回含重复的 3 本（id 2,3,4）
      final books2 = makeBooks(3, startId: 2);

      var callCount = 0;
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async {
        callCount++;
        return callCount == 1 ? books1 : books2;
      });

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );
      await Future.delayed(Duration.zero);

      // 第一次加载 3 本
      expect(provider.books.length, equals(3));

      // 加载更多
      await provider.loadMore();

      // 第二次只有 book4 是新的（book2, book3 重复）
      expect(provider.books.length, equals(4));
    });

    test('加载失败设置错误并停止', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenThrow(Exception('网络超时'));

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );
      await Future.delayed(Duration.zero);

      expect(provider.error, contains('网络超时'));
      expect(provider.hasMore, isFalse);
      expect(provider.loading, isFalse);
    });

    test('loading 中不重复请求', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => makeBooks(2));

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );

      // 在 loading 期间再次调用
      await provider.fetchBooks();
      await Future.delayed(Duration.zero);

      // 只应该请求一次（initData 触发的）
      verify(() => mockApi.exploreFetchBooks(any(), any(), any())).called(1);
    });

    test('hasMore 为 false 时不请求', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );
      await Future.delayed(Duration.zero);

      // hasMore 已经是 false
      await provider.fetchBooks();

      // 仍然只请求了一次
      verify(() => mockApi.exploreFetchBooks(any(), any(), any())).called(1);
    });

    test('source 为 null 时不请求', () async {
      await provider.fetchBooks();
      verifyNever(() => mockApi.exploreFetchBooks(any(), any(), any()));
    });
  });

  group('ExploreShowProvider refresh', () {
    test('刷新清空列表重新加载', () async {
      var callCount = 0;
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async {
        callCount++;
        return makeBooks(2, startId: callCount * 10);
      });

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );
      await Future.delayed(Duration.zero);

      expect(provider.books.length, equals(2));

      await provider.refresh();

      // 刷新后重新加载，页码重置
      expect(provider.page, equals(2));
      expect(provider.hasMore, isTrue);
      expect(provider.error, isNull);
    });
  });

  group('ExploreShowProvider isInBookshelf', () {
    test('当前实现始终返回 false', () {
      final book = const SearchBook(bookUrl: 'http://book.com/1', name: '书');
      expect(provider.isInBookshelf(book), isFalse);
    });
  });

  group('ExploreShowProvider books 不可变', () {
    test('books getter 返回不可修改列表', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => makeBooks(1));

      provider.initData(
        source: testSource,
        categoryName: '分类',
        categoryUrl: 'http://url.com',
      );
      await Future.delayed(Duration.zero);

      expect(
        () => provider.books.add(const SearchBook(bookUrl: 'x')),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
