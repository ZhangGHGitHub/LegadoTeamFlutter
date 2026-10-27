// RssArticlesScreen Widget 测试（批15d）
//
// 覆盖：
// - 分类 Tab 渲染与切换（多分类显示、单分类隐藏）
// - 触底自动加载更多（请求参数 page=2、加载中指示、追加结果、到底提示）
// - 搜索入口显隐（源 searchUrl 非空才显示）与关键词提交
// - 空态/错误态（ErrorView 重试）
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  const sourceUrl = 'https://s.test';
  const searchUrl = 'https://s.test/search';

  Map<String, dynamic> article(
    String title,
    String link, {
    String sort = '',
    int type = 0,
    String? image,
    String? pubDate,
  }) =>
      <String, dynamic>{
        'title': title,
        'link': link,
        'sort': sort,
        'type': type,
        'image': ?image,
        'pubDate': ?pubDate,
      };

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

  void stubSorts(MockRustApi api, RssSource source, List<RssSort> sorts) {
    when(() => api.rssSortUrls(source.sourceUrl)).thenAnswer(
      (_) async => jsonEncode([for (final s in sorts) s.toJson()]),
    );
  }

  /// 构造页面并返回容器（用于读取 Notifier 状态）
  ///
  /// [settle] 为 false 时只推进固定帧：列表项带封面图会触发
  /// `CachedNetworkImage` 占位动画，`pumpAndSettle` 会超时。
  Future<ProviderContainer> pumpScreen(
    WidgetTester tester,
    MockRustApi api,
    RssSource source, {
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: RssArticlesScreen(source: source)),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
    return container;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('多分类：渲染分类 Tab，点击切换分类并刷新列表', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [
      RssSort(name: '全部', url: sourceUrl),
      RssSort(name: '科技', url: '$sourceUrl/tech'),
    ]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '全部', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson([article('全部文章', '$sourceUrl/a', sort: '全部')]),
    );
    when(
      () => api.rssRefreshArticles(
        sourceUrl,
        '科技',
        '$sourceUrl/tech',
        key: null,
      ),
    ).thenAnswer(
      (_) async =>
          pageJson([article('科技文章', '$sourceUrl/b', sort: '科技')]),
    );

    final container = await pumpScreen(tester, api, source);

    // Tab 行渲染（单分类会隐藏，这里两条可见）
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('科技'), findsOneWidget);
    expect(find.text('全部文章'), findsOneWidget);

    await tester.tap(find.text('科技'));
    await tester.pumpAndSettle();

    expect(find.text('科技文章'), findsOneWidget);
    expect(find.text('全部文章'), findsNothing);
    expect(container.read(rssNotifierProvider).currentSort?.name, equals('科技'));
    verify(
      () => api.rssRefreshArticles(
        sourceUrl,
        '科技',
        '$sourceUrl/tech',
        key: null,
      ),
    ).called(1);
  });

  testWidgets('单分类：隐藏分类 Tab', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson([article('唯一文章', '$sourceUrl/a')]),
    );

    await pumpScreen(tester, api, source);

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('唯一文章'), findsOneWidget);
  });

  testWidgets('触底自动加载更多：请求 page=2 并追加结果', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    const nextUrl = '$sourceUrl?page=2';
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson(
        [for (var i = 1; i <= 20; i++) article('第 $i 篇', '$sourceUrl/$i')],
        nextUrl: nextUrl,
        hasMore: true,
      ),
    );
    final second = Completer<String>();
    when(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).thenAnswer((_) => second.future);

    final container = await pumpScreen(tester, api, source);
    expect(container.read(rssNotifierProvider).articles.length, equals(20));

    // 触底（ListView 滚到底部附近触发）
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 加载中指示（对齐参考版 LoadMoreView 文案）
    expect(find.text('加载中…'), findsOneWidget);
    verify(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).called(1);

    second.complete(
      pageJson([for (var i = 21; i <= 25; i++) article('第 $i 篇', '$sourceUrl/$i')]),
    );
    await tester.pumpAndSettle();

    final state = container.read(rssNotifierProvider);
    expect(state.articles.length, equals(25));
    expect(state.page, equals(2));
    expect(state.hasMore, isFalse);
    expect(state.loadingMore, isFalse);
    expect(state.isLoadingArticles, isFalse);
    // 到底提示（列表底部，文案对齐参考版）
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text('已经到底了~'), findsOneWidget);
  });

  testWidgets('首屏不足一屏且 hasMore=true：布局完成后自动加载下一页（P1-2）',
      (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    const nextUrl = '$sourceUrl?page=2';
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson(
        [
          article('第 1 篇', '$sourceUrl/1'),
          article('第 2 篇', '$sourceUrl/2'),
        ],
        nextUrl: nextUrl,
        hasMore: true,
      ),
    );
    when(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).thenAnswer(
      (_) async => pageJson(
        [
          article('第 3 篇', '$sourceUrl/3'),
          article('第 4 篇', '$sourceUrl/4'),
        ],
      ),
    );

    final container = await pumpScreen(tester, api, source);

    // 首屏 2 篇不足一屏，无滚动事件也必须自动发出第 2 页请求
    verify(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).called(1);
    final state = container.read(rssNotifierProvider);
    expect(state.articles.length, equals(4));
    expect(state.page, equals(2));
    expect(state.hasMore, isFalse);
    expect(find.text('第 3 篇'), findsOneWidget);
  });

  testWidgets('加载更多失败：footer 错误态 + 重试按钮（P2-1）', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    const nextUrl = '$sourceUrl?page=2';
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson(
        [for (var i = 1; i <= 20; i++) article('第 $i 篇', '$sourceUrl/$i')],
        nextUrl: nextUrl,
        hasMore: true,
      ),
    );
    when(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).thenThrow(const BridgeError(message: '下一页失败'));

    final container = await pumpScreen(tester, api, source);

    // 触底触发失败
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(rssNotifierProvider).loadMoreFailed, isTrue);
    // 关闭 SnackBar，避免与 footer 的同一错误文案重复并遮挡重试按钮
    ScaffoldMessenger.of(tester.element(find.byType(ListView)))
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('下一页失败'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);

    // 失败门控：再次触底不重发
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    verify(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).called(1);

    // 点击重试恢复
    when(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).thenAnswer(
      (_) async => pageJson(
        [for (var i = 21; i <= 25; i++) article('第 $i 篇', '$sourceUrl/$i')],
      ),
    );
    await tester.tap(find.widgetWithText(TextButton, '重试'));
    await tester.pumpAndSettle();

    // mocktail 的 verify 会消费已匹配调用，重试成功后只应新增 1 次请求
    verify(
      () => api.rssLoadMoreArticles(sourceUrl, '', nextUrl, 2, key: null),
    ).called(1);
    expect(container.read(rssNotifierProvider).articles.length, equals(25));
    expect(container.read(rssNotifierProvider).loadMoreFailed, isFalse);
  });

  testWidgets('刷新中隐藏 footer，刷新失败显示错误态（P2-2）', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([article('现有文章', '$sourceUrl/a')]));

    final container = await pumpScreen(tester, api, source);
    expect(find.text('已经到底了~'), findsOneWidget);

    // 刷新挂起：footer 隐藏，不显示「已经到底了~」
    final refresh = Completer<String>();
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) => refresh.future);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    expect(container.read(rssNotifierProvider).isLoadingArticles, isTrue);
    expect(find.text('已经到底了~'), findsNothing);
    expect(find.widgetWithText(TextButton, '加载更多'), findsNothing);

    // 刷新失败：footer 错误态 + 重试，不误显「已经到底了~」
    refresh.completeError(const BridgeError(message: '刷新失败'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('刷新失败'), findsWidgets);
    expect(find.text('已经到底了~'), findsNothing);
    expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);
    expect(find.text('现有文章'), findsOneWidget);
    // 收尾：等 SnackBar 动画结束
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('文章页阅读记录：条目可点击并透传 origin（P2-6）', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([article('列表文章', '$sourceUrl/a')]));
    when(() => api.rssListReadRecordsByOrigin(sourceUrl, null)).thenAnswer(
      (_) async => [
        {
          'origin': sourceUrl,
          'title': '历史文章',
          'link': '$sourceUrl/article/1',
          'read_time': 1700000000000,
        },
      ],
    );
    when(() => api.getRssSources()).thenAnswer((_) async => const [source]);
    when(() => api.isStarred(any())).thenAnswer((_) async => false);

    await pumpScreen(tester, api, source);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读记录'));
    await tester.pumpAndSettle();
    expect(find.text('历史文章'), findsOneWidget);

    await tester.tap(find.text('历史文章'));
    await tester.pumpAndSettle();

    final detail = tester.widget<RssArticleDetailScreen>(
      find.byType(RssArticleDetailScreen),
    );
    expect(detail.sourceUrl, equals(sourceUrl));
    expect(detail.sourceName, equals('源A'));
    expect(detail.article.title, equals('历史文章'));
    expect(detail.article.url, equals('$sourceUrl/article/1'));
  });

  testWidgets('文章页阅读记录：legacy 伪主键不传 origin（P2-6）', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([article('列表文章', '$sourceUrl/a')]));
    when(() => api.rssListReadRecordsByOrigin(sourceUrl, null)).thenAnswer(
      (_) async => [
        {
          'origin': sourceUrl,
          'title': '无链接文章',
          // Rust 仓库对空 link 落库的 legacy 伪主键
          'link': 'legacy:$sourceUrl:无链接文章',
          'read_time': 1700000000000,
        },
      ],
    );
    when(() => api.isStarred(any())).thenAnswer((_) async => false);

    await pumpScreen(tester, api, source);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无链接文章'));
    await tester.pumpAndSettle();

    final detail = tester.widget<RssArticleDetailScreen>(
      find.byType(RssArticleDetailScreen),
    );
    expect(detail.sourceUrl, isEmpty);
    expect(detail.article.url, isEmpty);
    // 无链接时也不应出现「在浏览器中查看原文」入口
    expect(find.text('在浏览器中查看原文'), findsNothing);
  });

  testWidgets('打开文章：rssMarkRead 透传 type/sort/image/pubDate（批20）',
      (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson([
        article(
          '图片文章',
          '$sourceUrl/pic.jpg',
          sort: '图片分类',
          type: 1,
          image: '$sourceUrl/cover.jpg',
          pubDate: '2026-10-27',
        ),
      ]),
    );
    // 批20：精确匹配扩展字段透传（未传 durPos 时调用方应保持省略）
    when(
      () => api.rssMarkRead(
        sourceUrl,
        '图片文章',
        link: '$sourceUrl/pic.jpg',
        type: 1,
        sort: '图片分类',
        image: '$sourceUrl/cover.jpg',
        pubDate: '2026-10-27',
      ),
    ).thenAnswer((_) async {});

    await pumpScreen(tester, api, source, settle: false);
    await tester.tap(find.text('图片文章'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    verify(
      () => api.rssMarkRead(
        sourceUrl,
        '图片文章',
        link: '$sourceUrl/pic.jpg',
        type: 1,
        sort: '图片分类',
        image: '$sourceUrl/cover.jpg',
        pubDate: '2026-10-27',
      ),
    ).called(1);
  });

  testWidgets('源未配置 searchUrl：不显示搜索入口', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([]));

    await pumpScreen(tester, api, source);

    expect(find.byTooltip('搜索'), findsNothing);
  });

  testWidgets('搜索入口：提交关键词后以「搜索」分类与 key 刷新', (tester) async {
    final api = MockRustApi();
    const source = RssSource(
      sourceUrl: sourceUrl,
      sourceName: '源A',
      searchUrl: searchUrl,
    );
    stubSorts(api, source, const [
      RssSort(name: '全部', url: sourceUrl),
      RssSort(name: '科技', url: '$sourceUrl/tech'),
    ]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '全部', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson([article('全部文章', '$sourceUrl/a', sort: '全部')]),
    );
    when(
      () => api.rssRefreshArticles(
        sourceUrl,
        '搜索',
        searchUrl,
        key: '红',
      ),
    ).thenAnswer(
      (_) async => pageJson([article('搜索结果', '$sourceUrl/s', sort: '搜索')]),
    );

    final container = await pumpScreen(tester, api, source);
    expect(find.byTooltip('搜索'), findsOneWidget);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '红');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('搜索结果'), findsOneWidget);
    expect(find.text('全部文章'), findsNothing);
    final state = container.read(rssNotifierProvider);
    expect(state.key, equals('红'));
    expect(state.sorts.length, equals(1));
    expect(state.sorts.first.name, equals('搜索'));
    verify(
      () => api.rssRefreshArticles(
        sourceUrl,
        '搜索',
        searchUrl,
        key: '红',
      ),
    ).called(1);
  });

  testWidgets('搜索态系统返回：先退出搜索而非退页', (tester) async {
    final api = MockRustApi();
    const source = RssSource(
      sourceUrl: sourceUrl,
      sourceName: '源A',
      searchUrl: searchUrl,
    );
    stubSorts(api, source, const [
      RssSort(name: '全部', url: sourceUrl),
      RssSort(name: '科技', url: '$sourceUrl/tech'),
    ]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '全部', sourceUrl, key: null),
    ).thenAnswer(
      (_) async => pageJson([article('全部文章', '$sourceUrl/a', sort: '全部')]),
    );
    when(
      () => api.rssRefreshArticles(
        sourceUrl,
        '搜索',
        searchUrl,
        key: '红',
      ),
    ).thenAnswer(
      (_) async => pageJson([article('搜索结果', '$sourceUrl/s', sort: '搜索')]),
    );

    final container = await pumpScreen(tester, api, source);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '红');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();
    expect(container.read(rssNotifierProvider).key, equals('红'));

    // 系统返回（PopScope 拦截）→ 退出搜索并回到原分类
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(RssArticlesScreen), findsOneWidget);
    expect(container.read(rssNotifierProvider).key, isNull);
    expect(container.read(rssNotifierProvider).currentSort?.name, equals('全部'));
  });

  testWidgets('加载失败且无文章：ErrorView 重试', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenThrow(const BridgeError(message: '列表加载失败'));

    final container = await pumpScreen(tester, api, source);

    expect(find.text('列表加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([article('恢复文章', '$sourceUrl/a')]));

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('恢复文章'), findsOneWidget);
    expect(container.read(rssNotifierProvider).error, isNull);
  });

  testWidgets('列表已有内容时刷新失败：SnackBar 提示且保留列表', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([article('现有文章', '$sourceUrl/a')]));

    await pumpScreen(tester, api, source);

    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenThrow(const BridgeError(message: '刷新失败'));
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('刷新失败'), findsWidgets);
    expect(find.text('现有文章'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('列表为空：展示空态', (tester) async {
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSorts(api, source, const [RssSort(name: '', url: sourceUrl)]);
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([]));

    await pumpScreen(tester, api, source);

    expect(find.text('暂无文章'), findsOneWidget);
  });
}
