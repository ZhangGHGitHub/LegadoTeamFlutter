// RssNotifier 分类 / 分页 / 搜索单元测试（批15d）
//
// 覆盖：
// - selectSource：rssSortUrls 加载分类（失败回退默认单分类）→ rssRefreshArticles
// - selectSort：分类切换、重复点击不重载、过期响应丢弃
// - search / clearSearch：搜索态单分类、退出搜索还原先前分类
// - loadMore：无下一页/空 nextUrl 短路、追加去重、到底、失败态
// - refreshSorts：clearSortCache → 重新解析 → 刷新当前分类（搜索态保持）
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  const sourceUrl = 'https://s.test';
  const searchUrl = 'https://s.test/search';
  const source = RssSource(
    sourceUrl: sourceUrl,
    sourceName: '源A',
    searchUrl: searchUrl,
  );

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({kRssSourceVersionKey: 6});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  RssState readState() => container.read(rssNotifierProvider);
  RssNotifier readNotifier() => container.read(rssNotifierProvider.notifier);

  Map<String, dynamic> article(String title, String link, {String sort = ''}) =>
      <String, dynamic>{'title': title, 'link': link, 'sort': sort};

  String pageJson(
    List<Map<String, dynamic>> articles, {
    String? nextUrl,
    bool hasMore = false,
  }) =>
      jsonEncode({
        'articles': articles,
        'nextUrl': nextUrl,
        'hasMore': hasMore,
      });

  /// 默认双分类 stub：全部（sourceUrl）/ 科技（/tech）
  void stubTwoSorts() {
    when(() => mockApi.rssSortUrls(sourceUrl)).thenAnswer(
      (_) async => jsonEncode([
        {'name': '全部', 'url': sourceUrl},
        {'name': '科技', 'url': '$sourceUrl/tech'},
      ]),
    );
  }

  void stubPage({
    required String sortName,
    required String sortUrl,
    required String json,
    String? key,
  }) {
    when(
      () => mockApi.rssRefreshArticles(
        sourceUrl,
        sortName,
        sortUrl,
        key: key,
      ),
    ).thenAnswer((_) async => json);
  }

  group('初始状态（批15d 新增字段）', () {
    test('分类/分页/搜索字段默认值', () {
      expect(readState().sorts, isEmpty);
      expect(readState().currentSort, isNull);
      expect(readState().nextUrl, isNull);
      expect(readState().hasMore, isFalse);
      expect(readState().loadingMore, isFalse);
      expect(readState().loadMoreFailed, isFalse);
      expect(readState().key, isNull);
      expect(readState().page, equals(1));
      expect(readState().isSearching, isFalse);
    });
  });

  group('selectSource：分类加载', () {
    test('加载多分类并选中首个，列表请求参数正确', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([article('文章1', '$sourceUrl/1')]),
      );

      await readNotifier().selectSource(source);

      expect(readState().selectedSource, equals(source));
      expect(readState().sorts.length, equals(2));
      expect(readState().sorts[1].name, equals('科技'));
      expect(readState().currentSort?.name, equals('全部'));
      expect(readState().articles.length, equals(1));
      expect(readState().isLoadingArticles, isFalse);
      expect(readState().error, isNull);
      expect(readState().page, equals(1));
      verify(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '全部',
          sourceUrl,
          key: null,
        ),
      ).called(1);
    });

    test('分类解析失败回退默认单分类且仍刷新列表', () async {
      when(() => mockApi.rssSortUrls(sourceUrl))
          .thenThrow(const BridgeError(message: '分类脚本失败'));
      stubPage(
        sortName: '',
        sortUrl: sourceUrl,
        json: pageJson([article('回退文章', '$sourceUrl/1')]),
      );

      await readNotifier().selectSource(source);

      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.name, isEmpty);
      expect(readState().sorts.first.url, equals(sourceUrl));
      expect(readState().currentSort, equals(readState().sorts.first));
      expect(readState().articles.first.title, equals('回退文章'));
      // 分类失败不阻断列表（不设置错误）
      expect(readState().error, isNull);
    });

    test('分类返回空数组时回退默认单分类', () async {
      when(() => mockApi.rssSortUrls(sourceUrl))
          .thenAnswer((_) async => jsonEncode(<dynamic>[]));
      stubPage(
        sortName: '',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );

      await readNotifier().selectSource(source);

      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.url, equals(sourceUrl));
    });

    test('分类加载中提交搜索：慢分类续体不得回写搜索态（P1-1）', () async {
      // 分类脚本可控延迟（模拟 @js: 网络求值）
      final slowSorts = Completer<String>();
      when(() => mockApi.rssSortUrls(sourceUrl))
          .thenAnswer((_) => slowSorts.future);
      stubPage(
        sortName: '搜索',
        sortUrl: searchUrl,
        json: pageJson([article('搜索结果', '$sourceUrl/s1', sort: '搜索')]),
        key: 'flutter',
      );
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([article('全部分类文章', '$sourceUrl/all', sort: '全部')]),
      );

      final selecting = readNotifier().selectSource(source);
      // 分类在途：界面已进入加载态
      await Future<void>.delayed(Duration.zero);
      expect(readState().isLoadingArticles, isTrue);
      expect(readState().sorts, isEmpty);

      // 分类未返回期间用户提交搜索
      await readNotifier().search('flutter');
      expect(readState().key, equals('flutter'));
      expect(readState().currentSort?.name, equals('搜索'));
      expect(readState().articles.first.title, equals('搜索结果'));

      // 慢分类返回：selectSource 续体应按请求代次整体丢弃
      slowSorts.complete(jsonEncode([
        {'name': '全部', 'url': sourceUrl},
        {'name': '科技', 'url': '$sourceUrl/tech'},
      ]));
      await selecting;

      expect(readState().key, equals('flutter'));
      expect(readState().isSearching, isTrue);
      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.name, equals('搜索'));
      expect(readState().currentSort?.name, equals('搜索'));
      expect(readState().articles.first.title, equals('搜索结果'));
      // 不得用「全部」分类覆盖搜索列表
      verifyNever(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '全部',
          sourceUrl,
          key: null,
        ),
      );
    });
  });

  group('selectSort：分类切换', () {
    test('切换分类清空旧文章并请求新分类', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([article('全部文章', '$sourceUrl/all', sort: '全部')]),
      );
      stubPage(
        sortName: '科技',
        sortUrl: '$sourceUrl/tech',
        json: pageJson([article('科技文章', '$sourceUrl/tech', sort: '科技')]),
      );

      await readNotifier().selectSource(source);
      await readNotifier()
          .selectSort(const RssSort(name: '科技', url: '$sourceUrl/tech'));

      expect(readState().currentSort?.name, equals('科技'));
      expect(readState().articles.length, equals(1));
      expect(readState().articles.first.title, equals('科技文章'));
      verify(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '科技',
          '$sourceUrl/tech',
          key: null,
        ),
      ).called(1);
    });

    test('重复点击同一分类不重新请求', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );

      await readNotifier().selectSource(source);
      await readNotifier().selectSort(readState().currentSort!);

      verify(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '全部',
          sourceUrl,
          key: null,
        ),
      ).called(1);
    });

    test('切换分类后过期响应被丢弃', () async {
      stubTwoSorts();
      final slow = Completer<String>();
      when(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '全部',
          sourceUrl,
          key: null,
        ),
      ).thenAnswer((_) => slow.future);
      stubPage(
        sortName: '科技',
        sortUrl: '$sourceUrl/tech',
        json: pageJson([article('科技文章', '$sourceUrl/tech', sort: '科技')]),
      );

      final selecting = readNotifier().selectSource(source);
      // 等待分类加载完成、首个分类请求进入在途状态
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(readState().isLoadingArticles, isTrue);

      await readNotifier()
          .selectSort(const RssSort(name: '科技', url: '$sourceUrl/tech'));
      expect(readState().articles.first.title, equals('科技文章'));

      // 旧分类的慢响应返回后不得覆盖新分类列表
      slow.complete(pageJson([article('过期文章', '$sourceUrl/stale')]));
      await selecting;
      expect(readState().currentSort?.name, equals('科技'));
      expect(readState().articles.first.title, equals('科技文章'));
    });
  });

  group('search / clearSearch', () {
    test('搜索切换为「搜索」单分类并透传 key', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );
      stubPage(
        sortName: '搜索',
        sortUrl: searchUrl,
        json: pageJson([article('搜索结果', '$sourceUrl/s1', sort: '搜索')]),
        key: 'flutter',
      );

      await readNotifier().selectSource(source);
      await readNotifier().search('flutter');

      expect(readState().key, equals('flutter'));
      expect(readState().isSearching, isTrue);
      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.name, equals('搜索'));
      expect(readState().sorts.first.url, equals(searchUrl));
      expect(readState().articles.first.title, equals('搜索结果'));
      verify(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '搜索',
          searchUrl,
          key: 'flutter',
        ),
      ).called(1);
    });

    test('空关键词退出搜索并还原先前分类', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([article('全部文章', '$sourceUrl/all', sort: '全部')]),
      );
      stubPage(
        sortName: '科技',
        sortUrl: '$sourceUrl/tech',
        json: pageJson([article('科技文章', '$sourceUrl/tech', sort: '科技')]),
      );
      stubPage(
        sortName: '搜索',
        sortUrl: searchUrl,
        json: pageJson([article('搜索结果', '$sourceUrl/s1', sort: '搜索')]),
        key: 'dart',
      );

      await readNotifier().selectSource(source);
      await readNotifier()
          .selectSort(const RssSort(name: '科技', url: '$sourceUrl/tech'));
      await readNotifier().search('dart');
      expect(readState().isSearching, isTrue);

      await readNotifier().search('   ');

      expect(readState().key, isNull);
      expect(readState().isSearching, isFalse);
      expect(readState().sorts.length, equals(2));
      expect(readState().currentSort?.name, equals('科技'));
      expect(readState().articles.first.title, equals('科技文章'));
    });

    test('源未配置 searchUrl 时搜索为空操作', () async {
      const noSearchSource = RssSource(sourceUrl: sourceUrl, sourceName: '无搜索');
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );

      await readNotifier().selectSource(noSearchSource);
      await readNotifier().search('flutter');

      expect(readState().key, isNull);
      expect(readState().sorts.length, equals(2));
      verifyNever(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '搜索',
          searchUrl,
          key: 'flutter',
        ),
      );
    });
  });

  group('loadMore：分页', () {
    Future<void> selectFirstPage({
      required String firstPageJson,
      int articles = 1,
    }) async {
      when(() => mockApi.rssSortUrls(sourceUrl)).thenAnswer(
        (_) async => jsonEncode([
          {'name': '', 'url': sourceUrl},
        ]),
      );
      stubPage(sortName: '', sortUrl: sourceUrl, json: firstPageJson);
      await readNotifier().selectSource(source);
      expect(readState().articles.length, equals(articles));
    }

    test('hasMore=false 时直接返回不请求', () async {
      await selectFirstPage(
        firstPageJson: pageJson([article('a', '$sourceUrl/1')]),
      );

      await readNotifier().loadMore();

      verifyNever(
        () => mockApi.rssLoadMoreArticles(
          sourceUrl,
          '',
          '',
          2,
          key: null,
        ),
      );
      expect(readState().page, equals(1));
    });

    test('hasMore=true 时请求 page+1 并追加去重', () async {
      const next = '$sourceUrl?page=2';
      await selectFirstPage(
        firstPageJson: pageJson(
          [article('a', '$sourceUrl/1')],
          nextUrl: next,
          hasMore: true,
        ),
      );
      expect(readState().hasMore, isTrue);
      expect(readState().nextUrl, equals(next));

      when(
        () => mockApi.rssLoadMoreArticles(sourceUrl, '', next, 2, key: null),
      ).thenAnswer(
        (_) async => pageJson(
          [
            // 与第一页重复的条目（对齐 DB INSERT OR IGNORE 不重复展示）
            article('a', '$sourceUrl/1'),
            article('b', '$sourceUrl/2'),
          ],
          nextUrl: next,
          hasMore: true,
        ),
      );

      await readNotifier().loadMore();

      expect(readState().articles.length, equals(2));
      expect(readState().articles.last.title, equals('b'));
      expect(readState().page, equals(2));
      expect(readState().loadingMore, isFalse);
      expect(readState().hasMore, isTrue);
    });

    test('下一页返回无 nextUrl 时判底', () async {
      const next = '$sourceUrl?page=2';
      await selectFirstPage(
        firstPageJson: pageJson(
          [article('a', '$sourceUrl/1')],
          nextUrl: next,
          hasMore: true,
        ),
      );
      when(
        () => mockApi.rssLoadMoreArticles(sourceUrl, '', next, 2, key: null),
      ).thenAnswer(
        (_) async => pageJson([article('b', '$sourceUrl/2')]),
      );

      await readNotifier().loadMore();

      expect(readState().hasMore, isFalse);
      expect(readState().nextUrl, isNull);
      expect(readState().articles.length, equals(2));
    });

    test('加载更多失败设置错误且保留已有列表', () async {
      const next = '$sourceUrl?page=2';
      await selectFirstPage(
        firstPageJson: pageJson(
          [article('a', '$sourceUrl/1')],
          nextUrl: next,
          hasMore: true,
        ),
      );
      when(
        () => mockApi.rssLoadMoreArticles(sourceUrl, '', next, 2, key: null),
      ).thenThrow(const BridgeError(message: '下一页失败'));

      await readNotifier().loadMore();

      expect(readState().error, equals('下一页失败'));
      expect(readState().loadingMore, isFalse);
      expect(readState().loadMoreFailed, isTrue);
      expect(readState().articles.length, equals(1));
      expect(readState().hasMore, isTrue);
    });

    test('加载更多失败后门控：滚动重发不请求，retryLoadMore 解除（P2-1）', () async {
      const next = '$sourceUrl?page=2';
      await selectFirstPage(
        firstPageJson: pageJson(
          [article('a', '$sourceUrl/1')],
          nextUrl: next,
          hasMore: true,
        ),
      );
      when(
        () => mockApi.rssLoadMoreArticles(sourceUrl, '', next, 2, key: null),
      ).thenThrow(const BridgeError(message: '下一页失败'));

      await readNotifier().loadMore();
      expect(readState().loadMoreFailed, isTrue);

      // 失败门控：滚动/首屏自动检查再次调用不再发请求
      await readNotifier().loadMore();
      verify(
        () => mockApi.rssLoadMoreArticles(sourceUrl, '', next, 2, key: null),
      ).called(1);

      // 用户点重试：解除门控并成功追加
      when(
        () => mockApi.rssLoadMoreArticles(sourceUrl, '', next, 2, key: null),
      ).thenAnswer(
        (_) async => pageJson([article('b', '$sourceUrl/2')]),
      );
      await readNotifier().retryLoadMore();

      // mocktail 的 verify 会消费已匹配调用，故重试后按「新增 1 次」校验
      verify(
        () => mockApi.rssLoadMoreArticles(sourceUrl, '', next, 2, key: null),
      ).called(1);
      expect(readState().loadMoreFailed, isFalse);
      expect(readState().error, isNull);
      expect(readState().articles.length, equals(2));
      expect(readState().page, equals(2));
    });

    test('刷新失败保留旧列表并设置错误', () async {
      when(() => mockApi.rssSortUrls(sourceUrl)).thenAnswer(
        (_) async => jsonEncode([
          {'name': '', 'url': sourceUrl},
        ]),
      );
      stubPage(
        sortName: '',
        sortUrl: sourceUrl,
        json: pageJson([article('a', '$sourceUrl/1')]),
      );
      await readNotifier().selectSource(source);

      when(
        () => mockApi.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
      ).thenThrow(const BridgeError(message: '刷新失败'));
      await readNotifier().refreshArticles();

      expect(readState().error, equals('刷新失败'));
      expect(readState().articles.length, equals(1));
      expect(readState().isLoadingArticles, isFalse);
    });
  });

  group('载荷形态不符显式报错（防复发规定 §4）', () {
    test('rssSortUrls 返回非数组：回退默认单分类且列表仍加载', () async {
      when(() => mockApi.rssSortUrls(sourceUrl))
          .thenAnswer((_) async => jsonEncode({'name': '', 'url': sourceUrl}));
      stubPage(
        sortName: '',
        sortUrl: sourceUrl,
        json: pageJson([article('回退文章', '$sourceUrl/1')]),
      );

      await readNotifier().selectSource(source);

      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.url, equals(sourceUrl));
      expect(readState().articles.first.title, equals('回退文章'));
    });

    test('rssSortUrls 项缺少 url：回退默认单分类', () async {
      when(() => mockApi.rssSortUrls(sourceUrl)).thenAnswer(
        (_) async => jsonEncode([
          {'name': '坏分类', 'url': ''},
        ]),
      );
      stubPage(
        sortName: '',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );

      await readNotifier().selectSource(source);

      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.url, equals(sourceUrl));
    });

    test('rssRefreshArticles 的 articles 非数组：显式错误而非静默空列表', () async {
      when(() => mockApi.rssSortUrls(sourceUrl)).thenAnswer(
        (_) async => jsonEncode([
          {'name': '', 'url': sourceUrl},
        ]),
      );
      when(
        () => mockApi.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
      ).thenAnswer(
        (_) async => jsonEncode({
          'articles': <String, dynamic>{},
          'nextUrl': null,
          'hasMore': false,
        }),
      );

      await readNotifier().selectSource(source);

      expect(readState().error, contains('articles 期望 JSON 数组'));
      expect(readState().isLoadingArticles, isFalse);
      expect(readState().articles, isEmpty);
    });

    test('rssRefreshArticles 列表项非对象：显式错误', () async {
      when(() => mockApi.rssSortUrls(sourceUrl)).thenAnswer(
        (_) async => jsonEncode([
          {'name': '', 'url': sourceUrl},
        ]),
      );
      when(
        () => mockApi.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
      ).thenAnswer(
        (_) async => jsonEncode({
          'articles': <dynamic>['bad-item'],
          'nextUrl': null,
          'hasMore': false,
        }),
      );

      await readNotifier().selectSource(source);

      expect(readState().error, contains('列表项期望 JSON 对象'));
      expect(readState().articles, isEmpty);
    });
  });

  group('refreshSorts：刷新排序', () {
    test('先清分类缓存再重新解析，保持当前分类并刷新列表', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );
      stubPage(
        sortName: '科技',
        sortUrl: '$sourceUrl/tech',
        json: pageJson([article('科技文章', '$sourceUrl/tech', sort: '科技')]),
      );
      when(() => mockApi.rssClearSortCache(sourceUrl)).thenAnswer((_) async {});

      await readNotifier().selectSource(source);
      await readNotifier()
          .selectSort(const RssSort(name: '科技', url: '$sourceUrl/tech'));
      await readNotifier().refreshSorts();

      verify(() => mockApi.rssClearSortCache(sourceUrl)).called(1);
      verify(() => mockApi.rssSortUrls(sourceUrl)).called(2);
      expect(readState().currentSort?.name, equals('科技'));
      expect(readState().sorts.length, equals(2));
      expect(readState().articles.first.title, equals('科技文章'));
      verify(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '科技',
          '$sourceUrl/tech',
          key: null,
        ),
      ).called(2);
    });

    test('搜索态刷新排序保持「搜索」分类并重拉结果', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );
      stubPage(
        sortName: '搜索',
        sortUrl: searchUrl,
        json: pageJson([article('搜索结果', '$sourceUrl/s1', sort: '搜索')]),
        key: 'dart',
      );
      when(() => mockApi.rssClearSortCache(sourceUrl)).thenAnswer((_) async {});

      await readNotifier().selectSource(source);
      await readNotifier().search('dart');
      await readNotifier().refreshSorts();

      verify(() => mockApi.rssClearSortCache(sourceUrl)).called(1);
      // 审查 P2-4：搜索态刷新排序不重新解析分类（对齐原版 upFragments
      // 的 searchKey != null 分支），rssSortUrls 仅 selectSource 时调用一次
      verify(() => mockApi.rssSortUrls(sourceUrl)).called(1);
      expect(readState().key, equals('dart'));
      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.name, equals('搜索'));
      expect(readState().articles.first.title, equals('搜索结果'));
      verify(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '搜索',
          searchUrl,
          key: 'dart',
        ),
      ).called(2);
    });

    test('刷新排序分类解析中提交搜索：慢分类续体不得回写（P1-1）', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([article('全部文章', '$sourceUrl/all', sort: '全部')]),
      );
      stubPage(
        sortName: '搜索',
        sortUrl: searchUrl,
        json: pageJson([article('搜索结果', '$sourceUrl/s1', sort: '搜索')]),
        key: 'dart',
      );
      when(() => mockApi.rssClearSortCache(sourceUrl)).thenAnswer((_) async {});

      await readNotifier().selectSource(source);

      // 第二次 rssSortUrls（刷新排序）挂起，模拟慢分类脚本
      final slowSorts = Completer<String>();
      when(() => mockApi.rssSortUrls(sourceUrl))
          .thenAnswer((_) => slowSorts.future);
      final refreshing = readNotifier().refreshSorts();
      await Future<void>.delayed(Duration.zero);

      await readNotifier().search('dart');
      expect(readState().key, equals('dart'));

      slowSorts.complete(jsonEncode([
        {'name': '全部', 'url': sourceUrl},
        {'name': '科技', 'url': '$sourceUrl/tech'},
      ]));
      await refreshing;

      // 慢分类结果被丢弃，搜索态与搜索结果保持不变
      expect(readState().key, equals('dart'));
      expect(readState().sorts.length, equals(1));
      expect(readState().sorts.first.name, equals('搜索'));
      expect(readState().currentSort?.name, equals('搜索'));
      expect(readState().articles.first.title, equals('搜索结果'));
      // refreshSorts 的续体没有再触发「全部」分类刷新
      verify(
        () => mockApi.rssRefreshArticles(
          sourceUrl,
          '全部',
          sourceUrl,
          key: null,
        ),
      ).called(1);
    });

    test('分类重新解析失败设置错误并保留原分类', () async {
      stubTwoSorts();
      stubPage(
        sortName: '全部',
        sortUrl: sourceUrl,
        json: pageJson([]),
      );
      when(() => mockApi.rssClearSortCache(sourceUrl)).thenAnswer((_) async {});
      await readNotifier().selectSource(source);

      when(() => mockApi.rssSortUrls(sourceUrl))
          .thenThrow(const BridgeError(message: '分类失败'));
      await readNotifier().refreshSorts();

      expect(readState().error, equals('分类失败'));
      expect(readState().sorts.length, equals(2));
      expect(readState().currentSort?.name, equals('全部'));
    });
  });
}
