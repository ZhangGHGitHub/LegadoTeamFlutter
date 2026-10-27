// RSS singleUrl 打开分流组件测试（批15g④）
//
// 对齐原版 `RssFragment.openRss`（`RssFragment.kt:180-196`）：
// - http(s) singleUrl → `ReadRssActivity.start(..., url)`（站内阅读 WebView）；
// - 非 http(s)（本地文件/自定义 scheme）→ 系统处理（原路径）。
// 另锁定 `ReadRssViewModel.kt:124-127`：singleUrl 源强制 URL 直开，
// 即使配置了 ruleContent 也不抓规则正文。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';
import 'package:flutter_legado/src/services/rss_web_config.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    // 跳过首启默认源导入（同 rss_history_entry_test：避免 rootBundle 缓存
    // Future 在 FakeAsync 新 Zone 中不完成）
    SharedPreferences.setMockInitialValues({kRssSourceVersionKey: 6});
  });

  Future<void> pumpRssScreen(
    WidgetTester tester,
    MockRustApi api, {
    required RssSource source,
    required String resolvedUrl,
  }) async {
    when(() => api.getRssSources()).thenAnswer((_) async => [source]);
    when(() => api.rssSortUrls(source.sourceUrl)).thenAnswer(
      (_) async => jsonEncode([
        {'name': '', 'url': resolvedUrl},
      ]),
    );
    when(() => api.isStarred(any())).thenAnswer((_) async => false);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: RssScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('http(s) singleUrl：进入站内阅读 WebView（不打开浏览器路由）', (tester) async {
    final api = MockRustApi();
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '单URL源',
      singleUrl: true,
    );
    await pumpRssScreen(
      tester,
      api,
      source: source,
      resolvedUrl: 'https://s.test/live',
    );

    await tester.tap(find.text('单URL源'));
    await tester.pumpAndSettle();

    expect(find.byType(RssArticleDetailScreen), findsOneWidget);
    expect(find.byType(RssArticlesScreen), findsNothing);
  });

  testWidgets('非 http(s) singleUrl：保持原路径（系统打开），不进阅读页', (tester) async {
    final api = MockRustApi();
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '本地源',
      singleUrl: true,
    );
    await pumpRssScreen(
      tester,
      api,
      source: source,
      resolvedUrl: 'file:///tmp/local-feed.xml',
    );

    await tester.tap(find.text('本地源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    // 原路径未被改道：不进入站内阅读页/文章列表，仅尝试系统打开。
    // （测试宿主的 url_launcher 方法通道无实现，launchUrl 返回 false 而非抛错）
    expect(find.byType(RssArticleDetailScreen), findsNothing);
    expect(find.byType(RssArticlesScreen), findsNothing);
    verify(() => api.rssSortUrls(source.sourceUrl)).called(1);
  });

  testWidgets('singleUrl 源详情页：强制 URL 直开，不抓规则正文', (tester) async {
    final api = MockRustApi();
    when(() => api.isStarred(any())).thenAnswer((_) async => false);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: RssArticleDetailScreen(
            article: const RssFeedArticle(
              title: '单URL源',
              url: 'https://s.test/live',
            ),
            sourceName: '单URL源',
            sourceUrl: 'https://s.test',
            source: const RssSource(
              sourceUrl: 'https://s.test',
              sourceName: '单URL源',
              singleUrl: true,
              // 有规则正文也必须忽略（原版 singleUrl 强制 loadUrl）
              ruleContent: '//div[@class="content"]',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    verifyNever(
      () => api.rssFetchContent(
        any(),
        any(),
        sort: any(named: 'sort'),
      ),
    );
  });

  group('rssIsHttpUrl（对齐 RssFragment.openRss 的 startsWith("http")）', () {
    test('http/https（大小写不敏感）为真', () {
      expect(rssIsHttpUrl('http://a.test'), isTrue);
      expect(rssIsHttpUrl('https://a.test/x'), isTrue);
      expect(rssIsHttpUrl('  HTTPS://A.TEST  '), isTrue);
    });

    test('其他 scheme/相对路径为假', () {
      expect(rssIsHttpUrl('file:///tmp/a.xml'), isFalse);
      expect(rssIsHttpUrl('snssdk1128://feed'), isFalse);
      expect(rssIsHttpUrl('httpx://a.test'), isFalse);
      expect(rssIsHttpUrl('/relative/path'), isFalse);
      expect(rssIsHttpUrl(''), isFalse);
    });
  });
}
