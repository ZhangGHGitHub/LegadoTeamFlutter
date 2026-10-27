// RSS singleUrl 打开分流组件测试（批15g④ / 批19 审查 P1、P2-5）
//
// 对齐原版 `RssFragment.openRss`（`RssFragment.kt:180-196`）：
// - http(s) singleUrl → `ReadRssActivity.start(..., url)`（站内阅读 WebView）；
// - 非 http(s)（本地文件/自定义 scheme）→ 系统处理（原路径）。
// 另锁定 `ReadRssViewModel.kt:124-127`：singleUrl 源强制 URL 直开，
// 即使配置了 ruleContent 也不抓规则正文。
//
// 批19 审查 P1：WebView 仅 Android/iOS/macOS 可用；Windows/Linux 不支持，
// http(s) singleUrl 必须保持原路径（内置浏览器页自动外开系统浏览器），
// 不能落进详情页「暂无内容」空态。本文件按平台分流分别断言。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// url_launcher_platform_interface 是 url_launcher 的传递依赖，
// 测试仅用它注入最小平台假实现（不改 pubspec）。
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/browser_screen.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';
import 'package:flutter_legado/src/services/rss_web_config.dart';
import 'package:flutter_legado/src/utils/webview_support.dart';

import '../mocks/fake_webview_platform.dart';
import '../mocks/mocks.dart';

/// 记录命名路由 push（断言分流目标）
class _RouteRecorder extends NavigatorObserver {
  final List<String?> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
    super.didPush(route, previousRoute);
  }
}

/// 最小 UrlLauncherPlatform 假实现：记录系统外开调用
class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

void main() {
  late _FakeUrlLauncherPlatform launcher;
  late UrlLauncherPlatform originalLauncher;

  setUpAll(() {
    registerFallbacks();
    // 支持 WebView 分支需要最小平台假实现（桌面宿主无真实实现）
    WebViewPlatform.instance = FakeWebViewPlatform();
  });

  setUp(() {
    // 跳过首启默认源导入（同 rss_history_entry_test：避免 rootBundle 缓存
    // Future 在 FakeAsync 新 Zone 中不完成）
    SharedPreferences.setMockInitialValues({kRssSourceVersionKey: 6});
    originalLauncher = UrlLauncherPlatform.instance;
    launcher = _FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalLauncher;
    debugSetWebViewSupportedOverride(null);
    FakeWebViewController.lastCreated = null;
  });

  Future<_RouteRecorder> pumpRssScreen(
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

    final observer = _RouteRecorder();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          navigatorObservers: [observer],
          home: const RssScreen(),
          onGenerateRoute: (settings) {
            if (settings.name == AppRoutes.browser) {
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => BrowserScreen(
                  initialUrl: settings.arguments as String?,
                ),
              );
            }
            return null;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    return observer;
  }

  testWidgets('支持 WebView 平台：http(s) singleUrl 进入站内阅读详情页', (tester) async {
    debugSetWebViewSupportedOverride(true);
    final api = MockRustApi();
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '单URL源',
      singleUrl: true,
    );
    final observer = await pumpRssScreen(
      tester,
      api,
      source: source,
      resolvedUrl: 'https://s.test/live',
    );

    await tester.tap(find.text('单URL源'));
    // 详情页 WebView 加载态含无限动画，不能 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(RssArticleDetailScreen), findsOneWidget);
    expect(find.byType(RssArticlesScreen), findsNothing);
    expect(observer.pushed, isNot(contains(AppRoutes.browser)));

    // P2-5：路由参数透传
    final detail = tester.widget<RssArticleDetailScreen>(
      find.byType(RssArticleDetailScreen),
    );
    expect(detail.article.url, 'https://s.test/live');
    expect(detail.sourceUrl, source.sourceUrl);
    expect(detail.source?.sourceUrl, source.sourceUrl);
    expect(detail.singleUrlDirect, isTrue);

    // P2-4：singleUrl 直开（原版无 rssArticle）隐藏收藏与文章头部
    final detailFinder = find.byType(RssArticleDetailScreen);
    expect(
      find.descendant(of: detailFinder, matching: find.byTooltip('收藏')),
      findsNothing,
    );
    expect(
      find.descendant(of: detailFinder, matching: find.text('单URL源')),
      findsNothing,
      reason: '文章头部应隐藏，避免与源名重复',
    );
  });

  testWidgets('不支持 WebView 平台：http(s) singleUrl 保持原路径自动外开', (tester) async {
    // P1 红→绿：Windows/Linux 桌面端不得进入详情页（否则「暂无内容」空态）
    debugSetWebViewSupportedOverride(false);
    final api = MockRustApi();
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '桌面源',
      singleUrl: true,
    );
    final observer = await pumpRssScreen(
      tester,
      api,
      source: source,
      resolvedUrl: 'https://s.test/live',
    );

    await tester.tap(find.text('桌面源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(observer.pushed, contains(AppRoutes.browser));
    expect(find.byType(BrowserScreen), findsOneWidget);
    expect(find.byType(RssArticleDetailScreen), findsNothing);
    expect(
      launcher.launched,
      ['https://s.test/live'],
      reason: '内置浏览器页在不支持 WebView 的平台应自动交系统浏览器打开',
    );
  });

  testWidgets('非 http(s) singleUrl：保持原路径（系统打开恰好一次），不进阅读页', (tester) async {
    final api = MockRustApi();
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '本地源',
      singleUrl: true,
    );
    final observer = await pumpRssScreen(
      tester,
      api,
      source: source,
      resolvedUrl: 'file:///tmp/local-feed.xml',
    );

    await tester.tap(find.text('本地源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    // 原路径未被改道：不进入站内阅读页/文章列表/内置浏览器页，
    // 仅通过 url_launcher 系统外开一次。
    expect(find.byType(RssArticleDetailScreen), findsNothing);
    expect(find.byType(RssArticlesScreen), findsNothing);
    expect(observer.pushed, isNot(contains(AppRoutes.browser)));
    expect(launcher.launched, ['file:///tmp/local-feed.xml']);
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
