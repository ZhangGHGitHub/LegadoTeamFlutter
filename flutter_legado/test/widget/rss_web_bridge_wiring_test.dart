// RSS 阅读页 WebView preloadJs 宿主桥接线组件测试（批21b）
//
// 覆盖：preloadJs 非空注册通道并内联组合脚本、为空不注册、enableJs=false
// 不执行、hello + java.put（__store）写穿 + getAwait 回调、ajaxAwait 失败
// 回调 ok=false、injectJs 裸执行、shouldOverrideUrlLoading 快照桩、
// console 钩子先于 preload、URL 模式 Cookie 预写/回流。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/utils/webview_support.dart';

import '../mocks/fake_webview_platform.dart';
import '../mocks/mocks.dart';

const String _sourceUrl = 'https://s.test/feed';
const String _articleUrl = 'https://s.test/a';
const String _rustHeadMarker = 'RUST_HEAD_MARKER';
const String _preloadMarker = 'PRELOAD_JS_MARKER';

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
    FakeWebViewPlatform.resetCookieManager();
    when(() => mockApi.isStarred(any())).thenAnswer((_) async => false);
    when(() => mockApi.rssWebViewHostCall(any(), any(), any()))
        .thenAnswer((invocation) async {
      final method = invocation.positionalArguments[1] as String;
      switch (method) {
        case '__prepare':
          return jsonEncode(<String, dynamic>{
            'ok': true,
            'value': <String, dynamic>{
              'script': '$_rustHeadMarker\n',
              'snapshot': <String, dynamic>{
                'sourceUrl': _sourceUrl,
                'sourceName': '源A',
                'userAgent': 'UA-Prepare',
                'loginHeader': '{"Cookie":"sid=1; theme=dark"}',
                'vars': <String, String>{'token': 't1'},
              },
            },
            'error': null,
          });
        case 'getAwait':
          return jsonEncode(<String, dynamic>{
            'ok': true,
            'value': '结果',
            'error': null,
          });
        case 'ajaxAwait':
          return jsonEncode(<String, dynamic>{
            'ok': false,
            'value': null,
            'error': '网络失败',
          });
        case '__store':
        case '__cookieSet':
          return jsonEncode(<String, dynamic>{
            'ok': true,
            'value': null,
            'error': null,
          });
        default:
          return jsonEncode(<String, dynamic>{
            'ok': false,
            'value': null,
            'error': '未知方法',
          });
      }
    });
  });

  Future<void> runWithWebView(Future<void> Function() body) async {
    debugSetWebViewSupportedOverride(true);
    try {
      await body();
    } finally {
      debugSetWebViewSupportedOverride(null);
    }
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    required RssSource source,
    String? description = '<p>正文</p>',
    String articleUrl = _articleUrl,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: RssArticleDetailScreen(
            article: RssFeedArticle(
              title: '文章',
              url: articleUrl,
              description: description,
            ),
            sourceName: source.sourceName,
            sourceUrl: source.sourceUrl,
            source: source,
          ),
        ),
      ),
    );
    // 引导链：解析源 → prepare（mock 立即返回）→ 初始化 WebView
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
  }

  /// 从 runJavaScript 调用序列提取 nonce
  String? extractNonce(List<String> calls) {
    final pattern = RegExp(r'window\["([^"]+_nonce)"\]\("([^"]+)"\)');
    for (final call in calls.reversed) {
      final match = pattern.firstMatch(call);
      if (match != null) return match.group(2);
    }
    return null;
  }

  String helloMessage() =>
      jsonEncode(<String, dynamic>{
        'nonce': null,
        'id': '',
        'method': 'hello',
        'args': '[]',
      });

  String pageMessage({
    required String method,
    required String nonce,
    String id = 'rss_1',
    String args = '[]',
  }) =>
      jsonEncode(<String, dynamic>{
        'nonce': nonce,
        'id': id,
        'method': method,
        'args': args,
      });

  testWidgets('preloadJs 非空：注册 JavaScriptChannel 并内联组合脚本', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        showWebLog: true,
      );
      await pumpScreen(tester, source: source);

      final controller = FakeWebViewController.lastCreated!;
      expect(controller.javaScriptChannels, hasLength(1),
          reason: 'preloadJs 非空必须注册宿主通道');
      expect(controller.javaScriptChannels.single.name,
          startsWith('__legado_rssNative_'));

      final html = controller.loadedHtml ?? '';
      expect(html, contains(_preloadMarker));
      expect(html, contains(_rustHeadMarker));
      final consoleIndex = html.indexOf('__legadoConsoleHooked');
      final rustIndex = html.indexOf(_rustHeadMarker);
      final preloadIndex = html.indexOf(_preloadMarker);
      expect(consoleIndex, greaterThanOrEqualTo(0));
      expect(consoleIndex, lessThan(rustIndex),
          reason: 'console 钩子必须先于桥头/preloadJs');
      expect(rustIndex, lessThan(preloadIndex));
      expect(html, contains('})();'));

      verify(() => mockApi.rssWebViewHostCall(_sourceUrl, '__prepare', any()))
          .called(1);
    });
  });

  testWidgets('preloadJs 为空：不注册通道、不 prepare、不注入桥', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(sourceUrl: _sourceUrl, sourceName: '源A');
      await pumpScreen(tester, source: source);

      final controller = FakeWebViewController.lastCreated!;
      expect(controller.javaScriptChannels, isEmpty);
      verifyNever(
        () => mockApi.rssWebViewHostCall(any(), '__prepare', any()),
      );
      expect(controller.loadedHtml ?? '', isNot(contains(_rustHeadMarker)));
    });
  });

  testWidgets('enableJs=false：不注册通道、不 prepare、不执行注入', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        injectJs: 'INJECT_JS',
        enableJs: false,
      );
      await pumpScreen(tester, source: source);

      final controller = FakeWebViewController.lastCreated!;
      expect(controller.javaScriptChannels, isEmpty);
      verifyNever(
        () => mockApi.rssWebViewHostCall(any(), '__prepare', any()),
      );
      controller.emitPageStarted(_articleUrl);
      controller.emitPageFinished(_articleUrl);
      await tester.pump();
      expect(controller.javaScriptCalls, isEmpty,
          reason: 'enableJs=false 时不得执行 preloadJs/injectJs/桥脚本');
      expect(controller.loadedHtml ?? '', isNot(contains(_rustHeadMarker)));
    });
  });

  testWidgets('prepare 失败：降级为无宿主绑定，正文仍加载并裸注入 preloadJs', (tester) async {
    when(() => mockApi.rssWebViewHostCall(any(), '__prepare', any()))
        .thenAnswer((_) async => jsonEncode(<String, dynamic>{
              'ok': false,
              'value': null,
              'error': '当前构建未启用 quickjs',
            }));
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
      );
      await pumpScreen(tester, source: source);

      final controller = FakeWebViewController.lastCreated!;
      expect(controller.javaScriptChannels, isEmpty,
          reason: 'prepare 失败不得注册通道');
      final html = controller.loadedHtml ?? '';
      expect(html, contains('正文'), reason: '正文不得被桥失败阻断');
      expect(html, contains(_preloadMarker), reason: '降级后保持 15f 裸注入');
      expect(html, isNot(contains(_rustHeadMarker)));
    });
  });

  testWidgets('hello + source.put 写穿 + getAwait 回调', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
      );
      await pumpScreen(tester, source: source);
      final controller = FakeWebViewController.lastCreated!;
      final channel = controller.javaScriptChannels.single;

      // 1) hello → 回填 nonce
      channel.onMessageReceived(
        JavaScriptMessage(message: helloMessage()),
      );
      await tester.pump();
      await tester.pump();
      final nonce = extractNonce(controller.javaScriptCalls);
      expect(nonce, isNotNull, reason: '握手必须回填 nonce');

      // 2) java.put 经 __store 写穿（无回调）
      channel.onMessageReceived(
        JavaScriptMessage(
          message: pageMessage(
            method: '__store',
            nonce: nonce!,
            id: 'store_1',
            args: '{"op":"sourcePut","key":"token","value":"v1"}',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      verify(
        () => mockApi.rssWebViewHostCall(
          _sourceUrl,
          '__store',
          '[{"op":"sourcePut","key":"token","value":"v1"}]',
        ),
      ).called(1);

      // 3) getAwait → 回调 window[cb](id, true, 结果)
      channel.onMessageReceived(
        JavaScriptMessage(
          message: pageMessage(
            method: 'getAwait',
            nonce: nonce,
            id: 'id-2',
            args: '["https://a"]',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      verify(
        () => mockApi.rssWebViewHostCall(
          _sourceUrl,
          'getAwait',
          '["https://a"]',
        ),
      ).called(1);
      expect(
        controller.javaScriptCalls.any(
          (js) => js.contains('"id-2"') && js.contains('true') && js.contains('结果'),
        ),
        isTrue,
      );
    });
  });

  testWidgets('ajaxAwait 失败：回调 ok=false', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
      );
      await pumpScreen(tester, source: source);
      final controller = FakeWebViewController.lastCreated!;
      final channel = controller.javaScriptChannels.single;

      channel.onMessageReceived(JavaScriptMessage(message: helloMessage()));
      await tester.pump();
      await tester.pump();
      final nonce = extractNonce(controller.javaScriptCalls)!;

      channel.onMessageReceived(
        JavaScriptMessage(
          message: pageMessage(
            method: 'ajaxAwait',
            nonce: nonce,
            id: 'id-ajax',
            args: '["https://a"]',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        controller.javaScriptCalls.any(
          (js) =>
              js.contains('"id-ajax"') &&
              js.contains('false') &&
              js.contains('网络失败'),
        ),
        isTrue,
      );
    });
  });

  testWidgets('injectJs 裸执行（不注入桥）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        injectJs: 'INJECT_JS_MARKER',
      );
      await pumpScreen(tester, source: source);
      final controller = FakeWebViewController.lastCreated!;

      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      controller.emitPageFinished(_articleUrl);
      await tester.pump();

      // HTML 模式：preload 已内联，onPageStarted 不得重复执行
      expect(
        controller.javaScriptCalls.where((js) => js.contains(_preloadMarker)),
        isEmpty,
        reason: 'HTML 模式 preloadJs 已内联，不得在 onPageStarted 重复执行',
      );
      final injectCall = controller.javaScriptCalls
          .firstWhere((js) => js.contains('INJECT_JS_MARKER'));
      expect(injectCall.trim(), 'INJECT_JS_MARKER',
          reason: 'injectJs 必须裸执行（1:1），不得包装桥脚本');
    });
  });

  testWidgets('shouldOverrideUrlLoading：注入 java 快照桩', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        shouldOverrideUrlLoading: 'url.length > 0',
      );
      await pumpScreen(tester, source: source);
      final controller = FakeWebViewController.lastCreated!;

      // 仅 shouldOverride：不注册通道，但 prepare 取快照
      expect(controller.javaScriptChannels, isEmpty);
      verify(() => mockApi.rssWebViewHostCall(_sourceUrl, '__prepare', any()))
          .called(1);

      controller.emitPageStarted(_articleUrl);
      await tester.pump();

      final overrideCall = controller.javaScriptCalls
          .firstWhere((js) => js.contains('window.__legadoJava'));
      expect(overrideCall, contains(_sourceUrl));
      expect(overrideCall, contains('getVariable'));
      expect(overrideCall, isNot(contains('postMessage')));
    });
  });

  testWidgets('URL 模式：console 钩子先于桥注入（每次页面开始注入一次）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        showWebLog: true,
        singleUrl: true,
      );
      await pumpScreen(
        tester,
        source: source,
        description: null,
      );
      final controller = FakeWebViewController.lastCreated!;
      expect(controller.loadedUri.toString(), _articleUrl,
          reason: 'singleUrl 源必须 URL 直开');

      controller.emitPageStarted(_articleUrl);
      await tester.pump();

      final consoleIndex = controller.javaScriptCalls.indexWhere(
        (js) => js.contains('__legadoConsoleHooked'),
      );
      final preloadIndex = controller.javaScriptCalls.indexWhere(
        (js) => js.contains(_preloadMarker),
      );
      expect(consoleIndex, greaterThanOrEqualTo(0));
      expect(preloadIndex, greaterThan(consoleIndex),
          reason: '顺序必须是 console 钩子 → bootstrap/preload');

      final composed = controller.javaScriptCalls[preloadIndex];
      expect(composed, contains(_rustHeadMarker));
      expect(composed, contains('__legado_rssNative_'));
      expect(composed, endsWith('})();\n'));

      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      expect(
        controller.javaScriptCalls.where((js) => js.contains(_preloadMarker)),
        hasLength(2),
        reason: '每次页面开始执行一次 preload（第二次导航新增一条）',
      );
    });
  });

  testWidgets('URL 模式：加载前预写 Cookie，onPageFinished 回流', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        singleUrl: true,
      );
      await pumpScreen(tester, source: source, description: null);
      final controller = FakeWebViewController.lastCreated!;

      // 预写：__prepare 快照 loginHeader 的 Cookie → WebView cookie jar
      final manager = FakeWebViewPlatform.cookieManager!;
      expect(
        manager.setCookieCalls.map((c) => '${c.name}=${c.value}'),
        containsAll(<String>['sid=1', 'theme=dark']),
      );
      expect(manager.setCookieCalls.first.domain, 's.test');

      // 回流：页面完成时读取 cookie jar → __cookieSet
      manager.cookies.addAll(<WebViewCookie>[
        const WebViewCookie(name: 'sid', value: '9', domain: 's.test'),
        const WebViewCookie(name: 'uid', value: 'u1', domain: 's.test'),
      ]);
      controller.emitPageFinished(_articleUrl);
      await tester.pump();
      await tester.pump();
      verify(
        () => mockApi.rssWebViewHostCall(
          _sourceUrl,
          '__cookieSet',
          '[{"url":"$_articleUrl","cookie":"sid=9; uid=u1"}]',
        ),
      ).called(1);
    });
  });
}
