// ExploreShowNotifier 单元测试
//
// 覆盖：args 初始状态/title/fetchBooks 分页/去重/空列表 hasMore/
// 加载失败/refresh/loadMore/守卫（hasMore=false、categoryUrl 空）
//
// 注意：exploreShowNotifierProvider 为 autoDispose family，
// 必须用 container.listen 维持订阅，否则 read 后实例立即被销毁。
import 'dart:async';

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

  // 辅助：规则支持页码的 family key（含 {{page}}）
  const pagedArgs = ExploreShowArgs(
    source: testSource,
    categoryName: '玄幻',
    categoryUrl: 'http://source.com/xuanhuan?page={{page}}',
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

      spawn(pagedArgs);
      await pumpInit();
      expect(readState(pagedArgs).displayPage, equals(1));

      await readNotifier(pagedArgs).skipToPage(3);

      expect(readState(pagedArgs).displayPage, equals(3));
      expect(readState(pagedArgs).books.length, equals(3));
      expect(readState(pagedArgs).books.first.name, equals('书籍30'));
      // 目标页有数据 → hasMore 保持 true（可继续加载下一页）
      expect(readState(pagedArgs).hasMore, isTrue);
    });

    test('跳页到空页后 hasMore 置 false（按该页结果）', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((invocation) async {
        final page = invocation.positionalArguments[2] as int;
        return page == 5 ? <SearchBook>[] : makeBooks(2);
      });

      spawn(pagedArgs);
      await pumpInit();

      await readNotifier(pagedArgs).skipToPage(5);

      expect(readState(pagedArgs).displayPage, equals(5));
      expect(readState(pagedArgs).books, isEmpty);
      expect(readState(pagedArgs).hasMore, isFalse);
    });

    test('规则不支持页码时 skipToPage 被忽略', () async {
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((_) async => makeBooks(2));

      spawn();
      await pumpInit();
      // 清掉首屏加载调用，确保后续校验只针对跳页
      clearInteractions(mockApi);

      await readNotifier().skipToPage(4);

      expect(readState().displayPage, equals(1));
      verifyNever(() => mockApi.exploreFetchBooks(any(), any(), any()));
    });

    test('跳页失败：displayPage 保留旧页，retry 重放目标页', () async {
      var failPage5 = true;
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((invocation) async {
        final page = invocation.positionalArguments[2] as int;
        if (page == 5 && failPage5) throw Exception('网络错误');
        return makeBooks(2, startId: page * 10);
      });

      spawn(pagedArgs);
      await pumpInit();
      expect(readState(pagedArgs).displayPage, equals(1));

      await readNotifier(pagedArgs).skipToPage(5);

      // 失败：顶栏页码不展示未成功加载的目标页
      expect(readState(pagedArgs).displayPage, equals(1));
      expect(readState(pagedArgs).error, contains('网络错误'));
      // page 仍指向目标页，供重试重放
      expect(readState(pagedArgs).page, equals(5));

      failPage5 = false;
      await readNotifier(pagedArgs).retry();

      expect(readState(pagedArgs).displayPage, equals(5));
      expect(readState(pagedArgs).books.first.name, equals('书籍50'));
      expect(readState(pagedArgs).error, isNull);
    });

    test('加载中跳页/加载更多互斥：进行中的抓取优先', () async {
      final gate = Completer<List<SearchBook>>();
      var calls = 0;
      when(() => mockApi.exploreFetchBooks(any(), any(), any()))
          .thenAnswer((invocation) async {
        calls++;
        final page = invocation.positionalArguments[2] as int;
        if (page == 2) return gate.future;
        return makeBooks(2, startId: page * 10);
      });

      spawn(pagedArgs);
      await pumpInit();
      expect(readState(pagedArgs).displayPage, equals(1));

      // 加载更多（第 2 页）挂起中
      final loadMore = readNotifier(pagedArgs).loadMore();
      await pumpEventQueue();
      expect(readState(pagedArgs).isLoading, isTrue);

      // 跳页请求被忽略：不会并发发起第 5 页抓取
      await readNotifier(pagedArgs).skipToPage(5);
      expect(readState(pagedArgs).page, equals(2));
      expect(calls, equals(2));

      gate.complete(makeBooks(2, startId: 20));
      await loadMore;
      // 互斥验证：本次完成的是第 2 页（未被跳页请求打断）
      expect(readState(pagedArgs).displayPage, equals(2));
      expect(readState(pagedArgs).books.length, equals(4));
    });
  });
}
