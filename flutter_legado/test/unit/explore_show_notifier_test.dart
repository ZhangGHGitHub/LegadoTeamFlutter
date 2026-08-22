// ExploreShowNotifier 单元测试
//
// 覆盖：args 初始状态/title/fetchBooks 分页/去重/空列表 hasMore/
// 加载失败/refresh/loadMore/守卫（hasMore=false、categoryUrl 空）
//
// 注意：exploreShowNotifierProvider 为 autoDispose family，
// 必须用 container.listen 维持订阅，否则 read 后实例立即被销毁。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_show_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  // 辅助：构造 BookSource
  const testSource = BookSource(
    bookSourceUrl: 'http://source.com',
    bookSourceName: '测试书源',
  );

  // 辅助：family key
  const args = ExploreShowArgs(
    source: testSource,
    categoryName: '玄幻',
    categoryUrl: 'http://source.com/xuanhuan',
  );

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  /// 等待 build() 微任务首次加载完成
  Future<void> pumpInit() async {
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
  }

  /// 触发 Notifier 创建并维持订阅（autoDispose 需保持监听才不被销毁）
  ProviderSubscription<ExploreShowState> spawn([ExploreShowArgs a = args]) =>
      container.listen(exploreShowNotifierProvider(a), (_, _) {});

  ExploreShowState readState([ExploreShowArgs a = args]) =>
      container.read(exploreShowNotifierProvider(a));
  ExploreShowNotifier readNotifier([ExploreShowArgs a = args]) =>
      container.read(exploreShowNotifierProvider(a).notifier);

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

  group('ExploreShowNotifier 初始状态', () {
    test('由 args 初始化书源/分类信息', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      spawn();
      await pumpInit();

      expect(readState().source, equals(testSource));
      expect(readState().categoryName, equals('玄幻'));
      expect(readState().categoryUrl, equals('http://source.com/xuanhuan'));
    });

    test('title 显示分类名 - 书源名', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      spawn();
      await pumpInit();

      expect(readState().title, equals('玄幻 - 测试书源'));
    });
  });

  group('ExploreShowNotifier fetchBooks', () {
    test('成功加载书籍并递增页码', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => makeBooks(5));

      spawn();
      await pumpInit();

      expect(readState().books.length, equals(5));
      expect(readState().displayPage, equals(1));
      expect(readState().page, equals(2));
      expect(readState().hasMore, isTrue);
      expect(readState().isLoading, isFalse);
    });

    test('空 bookUrl 时仍保留全部书籍（name+author 去重）', () async {
      final books = [
        const SearchBook(bookUrl: '', name: '书A', author: '作者1'),
        const SearchBook(bookUrl: '', name: '书B', author: '作者2'),
        const SearchBook(bookUrl: '', name: '书C', author: '作者3'),
      ];
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => books);

      spawn();
      await pumpInit();

      expect(readState().books.length, equals(3));
    });

    test('返回空列表时 hasMore 设为 false', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      spawn();
      await pumpInit();

      expect(readState().hasMore, isFalse);
    });

    test('去重逻辑：相同 bookUrl 不重复添加', () async {
      final books1 = makeBooks(3, startId: 1);
      final books2 = makeBooks(3, startId: 2);
      var callCount = 0;
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async {
        callCount++;
        return callCount == 1 ? books1 : books2;
      });

      spawn();
      await pumpInit();

      // 首次加载 3 本
      expect(readState().books.length, equals(3));

      // 加载更多：第二次返回 book2/3/4，仅 book4 为新
      await readNotifier().loadMore();
      expect(readState().books.length, equals(4));
    });

    test('加载失败设置错误并保留 hasMore（可重试）', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenThrow(Exception('网络超时'));

      spawn();
      await pumpInit();

      expect(readState().error, contains('网络超时'));
      // 错误后保留 hasMore，使「点击重试」可用（发现页修复 C1，对齐原版 fail()）
      expect(readState().hasMore, isTrue);
      expect(readState().isLoading, isFalse);
    });

    test('hasMore 为 false 时不再请求', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      spawn();
      await pumpInit(); // 自动加载 → 空列表 → hasMore=false

      await readNotifier().fetchBooks(); // 守卫：hasMore=false 直接返回

      verify(() => mockApi.exploreFetchBooks(any(), any(), any())).called(1);
    });
  });

  group('ExploreShowNotifier 守卫与刷新', () {
    test('categoryUrl 为空时不请求', () async {
      const emptyArgs = ExploreShowArgs(
        source: testSource,
        categoryName: 'x',
        categoryUrl: '',
      );
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => []);

      spawn(emptyArgs);
      await pumpInit();

      verifyNever(() => mockApi.exploreFetchBooks(any(), any(), any()));
    });

    test('refresh 清空列表重新加载并重置页码', () async {
      var callCount = 0;
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async {
        callCount++;
        return makeBooks(2, startId: callCount * 10);
      });

      spawn();
      await pumpInit();
      expect(readState().books.length, equals(2));

      await readNotifier().refresh();

      expect(readState().displayPage, equals(1));
      expect(readState().page, equals(2));
      expect(readState().hasMore, isTrue);
      expect(readState().error, isNull);
    });

    test('skipToPage 跳页后仅展示目标页数据', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((invocation) async {
        final page = invocation.positionalArguments[2] as int;
        return makeBooks(3, startId: page * 10);
      });

      spawn();
      await pumpInit();
      expect(readState().displayPage, equals(1));

      await readNotifier().skipToPage(3);

      expect(readState().displayPage, equals(3));
      expect(readState().books.length, equals(3));
      expect(readState().books.first.name, equals('书籍30'));
    });
  });
}
