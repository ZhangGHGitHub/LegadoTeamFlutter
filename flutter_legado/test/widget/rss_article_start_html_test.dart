// RSS 详情页起始页（startHtml）渲染组件测试（批15f 审查 P0-1）
//
// 根因：`_buildArticleContent` 只认 `_articleHtml != null` 或 `_urlMode`，
// 起始页模式两者皆不成立 → WebView 已初始化却永远渲染「暂无内容」空态。
//
// 桌面测试环境不支持真实 WebView，本文件注入最小 `WebViewPlatform` 假实现
// 并打开 `debugWebViewSupportedOverride`，验证 startHtml 非空时进入 WebView
// 渲染分支。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';

import '../mocks/fake_webview_platform.dart';
import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
    WebViewPlatform.instance = FakeWebViewPlatform();
  });

  setUp(() {
    mockApi = MockRustApi();
    SharedPreferences.setMockInitialValues({});
    FakeWebViewController.lastCreated = null;
    when(() => mockApi.isStarred(any())).thenAnswer((_) async => false);
  });

  /// 以「支持 WebView」语义执行用例（结束前复位测试开关）
  Future<void> runWithWebView(Future<void> Function() body) async {
    RssArticleDetailScreen.debugWebViewSupportedOverride = true;
    try {
      await body();
    } finally {
      RssArticleDetailScreen.debugWebViewSupportedOverride = null;
    }
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    required String? startHtml,
    String articleUrl = 'https://s.test/start',
    String sourceUrl = 'https://s.test',
    String? header,
    String? description,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: RssArticleDetailScreen(
            article: RssFeedArticle(
              title: '起始页文章',
              url: articleUrl,
              description: description,
            ),
            sourceName: '源A',
            sourceUrl: sourceUrl,
            source: RssSource(
              sourceUrl: sourceUrl,
              sourceName: '源A',
              startJs: 'init()',
              header: header,
            ),
            startHtml: startHtml,
          ),
        ),
      ),
    );
    // 引导链：解析源 → 初始化 WebView（假平台同步完成）→ setState
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('startHtml 非空：渲染 WebView 而非「暂无内容」空态', (tester) async {
    await runWithWebView(() async {
      await pumpScreen(tester, startHtml: '<html><body>起始页</body></html>');

      expect(find.byType(WebViewWidget), findsOneWidget);
      expect(find.text('暂无内容'), findsNothing, reason: 'P0-1：起始页模式不得落到空态分支');
    });
  });

  testWidgets('startHtml 优先于文章自带正文：仍渲染起始页 WebView', (tester) async {
    await runWithWebView(() async {
      await pumpScreen(
        tester,
        startHtml: '<html><body>起始页</body></html>',
        description: '<p>自带正文</p>',
      );

      expect(find.byType(WebViewWidget), findsOneWidget);
      expect(
        find.textContaining('自带正文'),
        findsNothing,
        reason: '起始页分支优先，不能落到自带正文的纯文本渲染',
      );
    });
  });

  testWidgets('startHtml 为空：无正文时仍显示空态（既有行为不回退）', (tester) async {
    await runWithWebView(() async {
      await pumpScreen(tester, startHtml: null, articleUrl: '', sourceUrl: '');

      expect(find.byType(WebViewWidget), findsNothing);
      expect(find.text('暂无内容'), findsOneWidget);
    });
  });

  testWidgets('源 header 无 UA：回落全局 PrefKeys.userAgent（P2-2）', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.userAgent: 'GlobalUA/1.0',
    });
    await runWithWebView(() async {
      await pumpScreen(tester, startHtml: '<html><body>起始页</body></html>');

      expect(
        FakeWebViewController.lastCreated?.userAgent,
        'GlobalUA/1.0',
        reason: '源 header 未配置 UA 时必须读取全局 UserAgent 设置',
      );
    });
  });

  testWidgets('源 header 配置 UA：优先于全局设置', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.userAgent: 'GlobalUA/1.0',
    });
    await runWithWebView(() async {
      await pumpScreen(
        tester,
        startHtml: '<html><body>起始页</body></html>',
        header: 'User-Agent: HeaderUA/2.0',
      );

      expect(FakeWebViewController.lastCreated?.userAgent, 'HeaderUA/2.0');
    });
  });
}
