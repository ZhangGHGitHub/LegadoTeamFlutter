// RSS 首屏本地缓存 + 初始 sortUrl 覆盖单测（批15f）
//
// 覆盖：
// - selectSource 先在 rssListCachedArticles 结果上渲染，再等待网络刷新
// - 缓存查询失败静默，不阻断网络刷新
// - 初始 sortUrl 覆盖经 rssSortUrls(sortUrl:) 透传
// - 切换分类同样先展示该分类缓存
// - RssFeedArticle.type 兼容列表载荷 articleType
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  const sourceUrl = 'https://s.test';
  const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
  const overrideJson = '{"科技":"https://s.test/tech"}';

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

  String pageJson(List<Map<String, dynamic>> articles, {String? nextUrl}) =>
      jsonEncode({
        'articles': articles,
        'nextUrl': nextUrl,
        'hasMore': nextUrl != null,
      });

  void stubTwoSorts() {
    when(() => mockApi.rssSortUrls(sourceUrl)).thenAnswer(
      (_) async => jsonEncode([
        {'name': '全部', 'url': sourceUrl},
        {'name': '科技', 'url': '$sourceUrl/tech'},
      ]),
    );
  }

  /// 让事件循环跑完当前微任务链（缓存 → 网络请求进入挂起）
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

  test('selectSource：先渲染本地缓存，网络返回后替换', () async {
    stubTwoSorts();
    when(
      () => mockApi.rssListCachedArticles(sourceUrl, sortName: '全部'),
    ).thenAnswer(
      (_) async => jsonEncode([
        {
          'title': '缓存文章',
          'link': 'https://s.test/cached',
          'sort': '全部',
          'description': '缓存描述',
          'type': 0,
        },
      ]),
    );
    final network = Completer<String>();
    when(
      () => mockApi.rssRefreshArticles(
        sourceUrl,
        '全部',
        sourceUrl,
        key: null,
      ),
    ).thenAnswer((_) => network.future);

    final future = readNotifier().selectSource(source);
    await settle();
    expect(readState().articles.single.title, '缓存文章');
    expect(readState().isLoadingArticles, isTrue, reason: '网络刷新仍在途');

    network.complete(pageJson([
      {'title': '网络文章', 'link': 'https://s.test/online', 'sort': '全部'},
    ]));
    await future;
    expect(readState().articles.single.title, '网络文章');
    expect(readState().isLoadingArticles, isFalse);
  });

  test('缓存查询失败静默：网络刷新照常完成', () async {
    stubTwoSorts();
    // 不 stub rssListCachedArticles → 抛 MissingStubError，应被静默吞掉
    when(
      () => mockApi.rssRefreshArticles(
        sourceUrl,
        '全部',
        sourceUrl,
        key: null,
      ),
    ).thenAnswer(
      (_) async => pageJson([
        {'title': '网络文章', 'link': 'https://s.test/online', 'sort': '全部'},
      ]),
    );

    await readNotifier().selectSource(source);
    expect(readState().articles.single.title, '网络文章');
    expect(readState().error, isNull);
  });

  test('初始 sortUrl 覆盖：透传 rssSortUrls(sortUrl:) 并按覆盖分类刷新', () async {
    when(
      () => mockApi.rssSortUrls(sourceUrl, sortUrl: overrideJson),
    ).thenAnswer(
      (_) async => jsonEncode([
        {'name': '科技', 'url': 'https://s.test/tech'},
      ]),
    );
    when(
      () => mockApi.rssRefreshArticles(
        sourceUrl,
        '科技',
        'https://s.test/tech',
        key: null,
      ),
    ).thenAnswer(
      (_) async => pageJson([
        {'title': '科技文章', 'link': 'https://s.test/tech/1', 'sort': '科技'},
      ]),
    );

    await readNotifier().selectSource(source, sortUrl: overrideJson);
    expect(readState().sorts.length, 1);
    expect(readState().currentSort?.name, '科技');
    expect(readState().articles.single.title, '科技文章');
    verify(() => mockApi.rssSortUrls(sourceUrl, sortUrl: overrideJson))
        .called(1);
    verifyNever(() => mockApi.rssSortUrls(sourceUrl));
  });

  test('初始 sortUrl 覆盖解析失败：回退单条覆盖值且仍刷新', () async {
    when(
      () => mockApi.rssSortUrls(sourceUrl, sortUrl: 'https://s.test/only'),
    ).thenThrow(Exception('解析失败'));
    when(
      () => mockApi.rssRefreshArticles(
        sourceUrl,
        '',
        'https://s.test/only',
        key: null,
      ),
    ).thenAnswer((_) async => pageJson(const []));

    await readNotifier().selectSource(source, sortUrl: 'https://s.test/only');
    expect(readState().currentSort?.url, 'https://s.test/only');
    expect(readState().currentSort?.name, '');
  });

  test('selectSort：先展示目标分类缓存，再网络刷新', () async {
    stubTwoSorts();
    when(
      () => mockApi.rssListCachedArticles(sourceUrl, sortName: '全部'),
    ).thenAnswer((_) async => '[]');
    when(
      () => mockApi.rssListCachedArticles(sourceUrl, sortName: '科技'),
    ).thenAnswer(
      (_) async => jsonEncode([
        {'title': '科技缓存', 'link': 'https://s.test/c', 'sort': '科技'},
      ]),
    );
    when(
      () => mockApi.rssRefreshArticles(
        sourceUrl,
        '全部',
        sourceUrl,
        key: null,
      ),
    ).thenAnswer(
      (_) async => pageJson([
        {'title': '全部文章', 'link': 'https://s.test/a', 'sort': '全部'},
      ]),
    );
    final network = Completer<String>();
    when(
      () => mockApi.rssRefreshArticles(
        sourceUrl,
        '科技',
        '$sourceUrl/tech',
        key: null,
      ),
    ).thenAnswer((_) => network.future);

    await readNotifier().selectSource(source);
    final techSort = readState().sorts[1];
    final future = readNotifier().selectSort(techSort);
    await settle();
    expect(readState().articles.single.title, '科技缓存');
    expect(readState().isLoadingArticles, isTrue);

    network.complete(pageJson([
      {'title': '科技网络', 'link': 'https://s.test/t', 'sort': '科技'},
    ]));
    await future;
    expect(readState().articles.single.title, '科技网络');
  });

  test('RssFeedArticle.type：兼容 type / articleType 字段', () {
    expect(
      RssFeedArticle.fromJson({'title': 'a', 'link': 'u', 'type': 2}).type,
      2,
    );
    expect(
      RssFeedArticle.fromJson(
        {'title': 'a', 'link': 'u', 'articleType': 1},
      ).type,
      1,
    );
    expect(RssFeedArticle.fromJson({'title': 'a', 'link': 'u'}).type, 0);
    expect(
      RssFeedArticle.fromJson({'title': 'a', 'link': 'u', 'type': '2'}).type,
      2,
    );
  });

  group('阅读分流类型（resolveRssArticleType）', () {
    test('文章 type 非 0 优先', () {
      expect(resolveRssArticleType(articleType: 2, sourceType: 1), 2);
      expect(resolveRssArticleType(articleType: 1, sourceType: 2), 1);
    });

    test('文章 type 为 0 时回退源 type', () {
      expect(resolveRssArticleType(articleType: 0, sourceType: 1), 1);
      expect(resolveRssArticleType(articleType: 0, sourceType: 2), 2);
      expect(resolveRssArticleType(articleType: 0, sourceType: 0), 0);
      expect(resolveRssArticleType(articleType: 0), 0);
    });
  });

  group('singleUrl 首项（firstRssSortUrlFromJson）', () {
    test('取首项 url 并 trim', () {
      expect(
        firstRssSortUrlFromJson(
          jsonEncode([
            {'name': '科技', 'url': '  https://s.test/tech  '},
            {'name': '文学', 'url': 'https://s.test/lit'},
          ]),
        ),
        'https://s.test/tech',
      );
    });

    test('空数组 / 首项无 url / 形态不符 → null', () {
      expect(firstRssSortUrlFromJson('[]'), isNull);
      expect(firstRssSortUrlFromJson('[{"name":"a"}]'), isNull);
      expect(firstRssSortUrlFromJson('[{"name":"a","url":"  "}]'), isNull);
      expect(firstRssSortUrlFromJson('["x"]'), isNull);
      expect(firstRssSortUrlFromJson('{}'), isNull);
      expect(firstRssSortUrlFromJson('not json'), isNull);
    });
  });
}
