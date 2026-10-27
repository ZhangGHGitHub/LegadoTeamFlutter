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
    FakeWebViewPlatform.failNextJavaScriptChannelAdd = false;
    when(() => mockApi.isStarred(any())).thenAnswer((_) async => false);
    when(() => mockApi.rssWebViewHostCall(any(), any(), any()))
        .thenAnswer((invocation) async {
      final method = invocation.positionalArguments[1] as String;
      switch (method) {
        case '__prepare':
          return jsonEncode(<String, dynamic>{
            'ok': true,
            'value': <String, dynamic>{
              // 合法未闭合 IIFE 头（与 Rust 桥头拼接口径一致）
              'script': '(() => {\n  var __mockRustHead = 1; // $_rustHeadMarker\n',
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

  /// 从 runJavaScript 调用序列提取 nonce 与握手代数令牌
  ({String nonce, int token})? extractHandshake(List<String> calls) {
    final pattern = RegExp(r'window\["([^"]+)"\]\("([^"]+)",\s*(\d+)\)');
    for (final call in calls.reversed) {
      final match = pattern.firstMatch(call);
      if (match != null) {
        return (nonce: match.group(2)!, token: int.parse(match.group(3)!));
      }
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

  /// 看门狗重发脚本（`rssBridgeHelloScript` 的固定前缀；与 bootstrap 内
  /// `__lgHello` 定义区分）
  bool isWatchdogHello(String js) =>
      js.trimLeft().startsWith('try{var r=window[');

  String nonceAckMessage(String nonce, int token) =>
      jsonEncode(<String, dynamic>{
        'nonce': nonce,
        'id': '',
        'method': 'nonceAck',
        'args': '$token',
      });

  /// 完成 hello → nonce 回填 → 页面 ACK
  Future<({String nonce, int token})> completeHandshake(
    WidgetTester tester,
    dynamic channel,
    FakeWebViewController controller,
  ) async {
    channel.onMessageReceived(JavaScriptMessage(message: helloMessage()));
    await tester.pump();
    await tester.pump();
    final handshake = extractHandshake(controller.javaScriptCalls);
    expect(handshake, isNotNull, reason: '握手必须回填 nonce');
    channel.onMessageReceived(
      JavaScriptMessage(
        message: nonceAckMessage(handshake!.nonce, handshake.token),
      ),
    );
    await tester.pump();
    return handshake;
  }

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

  testWidgets('preloadJs 为空：不注册通道、仍取快照（Cookie 预写/同步面）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(sourceUrl: _sourceUrl, sourceName: '源A');
      await pumpScreen(tester, source: source);

      final controller = FakeWebViewController.lastCreated!;
      expect(controller.javaScriptChannels, isEmpty);
      // 批21c P2-4：快照生成与 preloadJs/JS 门控解耦，必须 prepare
      verify(() => mockApi.rssWebViewHostCall(_sourceUrl, '__prepare', any()))
          .called(1);
      expect(controller.loadedHtml ?? '', isNot(contains(_rustHeadMarker)));
    });
  });

  testWidgets('enableJs=false：不注册通道、不执行注入，但仍取快照', (tester) async {
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
      // 批21c P2-4：Cookie 预写依赖快照，JS 关闭也要 prepare
      verify(() => mockApi.rssWebViewHostCall(_sourceUrl, '__prepare', any()))
          .called(1);
      controller.emitPageStarted(_articleUrl);
      controller.emitPageFinished(_articleUrl);
      await tester.pump();
      expect(controller.javaScriptCalls, isEmpty,
          reason: 'enableJs=false 时不得执行 preloadJs/injectJs/桥脚本');
      expect(controller.loadedHtml ?? '', isNot(contains(_rustHeadMarker)));
    });
  });

  testWidgets('bridgeAvailable:false/空桥头：注入降级桩而非裸 preloadJs（P2-1）', (tester) async {
    when(() => mockApi.rssWebViewHostCall(any(), '__prepare', any()))
        .thenAnswer((_) async => jsonEncode(<String, dynamic>{
              'ok': true,
              'value': <String, dynamic>{
                'script': '',
                'bridgeAvailable': false,
                'snapshot': <String, dynamic>{
                  'sourceUrl': _sourceUrl,
                  'sourceName': '源A',
                  'loginHeader': '{"Cookie":"sid=1"}',
                },
              },
              'error': null,
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
          reason: 'bridgeAvailable:false 不得注册通道');
      final html = controller.loadedHtml ?? '';
      expect(html, contains('正文'));
      expect(html, contains(_preloadMarker));
      expect(html, contains('宿主桥不可用（prepare 失败或桥不可用）'),
          reason: '空桥头/桥不可用必须注入引导式降级桩');
      expect(html, isNot(contains(_rustHeadMarker)));
    });
  });

  testWidgets('prepare 失败：注入引导式降级桩，正文仍加载', (tester) async {
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
      expect(html, contains(_preloadMarker), reason: '降级后仍执行 preloadJs');
      expect(html, contains('宿主桥不可用（prepare 失败或桥不可用）'),
          reason: '必须注入引导式降级桩');
      expect(html, isNot(contains(_rustHeadMarker)));

      // HTML 模式：首文档已内联，第二次页面开始（新文档）注入降级桩
      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      controller.emitPageStarted('https://s.test/second');
      await tester.pump();
      expect(
        controller.javaScriptCalls.where(
          (js) => js.contains('宿主桥不可用（prepare 失败或桥不可用）'),
        ),
        isNotEmpty,
        reason: 'onPageStarted 降级注入必须走 composeInjection',
      );
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

      // 1) hello → 回填 nonce → nonceAck
      final handshake = await completeHandshake(tester, channel, controller);
      final nonce = handshake.nonce;

      // 2) java.put 经 __store 写穿（无回调）
      channel.onMessageReceived(
        JavaScriptMessage(
          message: pageMessage(
            method: '__store',
            nonce: nonce,
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

      final handshake = await completeHandshake(tester, channel, controller);
      final nonce = handshake.nonce;

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

  testWidgets('HTML 模式：首文档跳过重复注入，二次导航重新注入桥（P1-2）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
      );
      await pumpScreen(tester, source: source);
      final controller = FakeWebViewController.lastCreated!;

      // 首文档组合脚本已内联 → onPageStarted 不得重复执行 preloadJs
      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      expect(
        controller.javaScriptCalls.where((js) => js.contains(_preloadMarker)),
        isEmpty,
        reason: '首文档已内联，不得重复执行',
      );

      // 点击链接后的新文档：onPageStarted 必须重新注入完整组合脚本
      controller.emitPageStarted('https://s.test/second');
      await tester.pump();
      final calls = controller.javaScriptCalls
          .where((js) => js.contains(_preloadMarker))
          .toList();
      expect(calls, hasLength(1), reason: '二次导航必须重新注入桥');
      expect(calls.single, contains(_rustHeadMarker));
      expect(calls.single, contains('__legado_rssNative_'));
      expect(calls.single.trimRight(), endsWith('})();'));
    });
  });

  testWidgets('桥模式：剥离页面脚本/内联事件/javascript: URL（P0-2）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
      );
      const dangerous = '<p>正文</p>'
          '<script>alert("page-script-marker")</script>'
          '<img src="x" onerror="alert(1)">'
          '<a href="javascript:alert(2)">链接</a>';
      await pumpScreen(tester, source: source, description: dangerous);

      final html = FakeWebViewController.lastCreated!.loadedHtml ?? '';
      expect(html, contains('正文'));
      expect(html, isNot(contains('page-script-marker')),
          reason: '页面 <script> 必须剥离');
      expect(html, isNot(contains('onerror')), reason: 'on* 内联事件必须剥离');
      expect(html, isNot(contains('javascript:')),
          reason: 'javascript: URL 必须剥离');
      // 应用自己的注入脚本保留
      expect(html, contains(_preloadMarker));
      expect(html, contains(_rustHeadMarker));
    });
  });

  testWidgets('非桥模式：保留页面脚本（不剥离）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(sourceUrl: _sourceUrl, sourceName: '源A');
      await pumpScreen(
        tester,
        source: source,
        description: '<p>正文</p><script>window.KEEP_MARKER = 1;</script>',
      );
      final html = FakeWebViewController.lastCreated!.loadedHtml ?? '';
      expect(html, contains('KEEP_MARKER'));
    });
  });

  testWidgets('HTML 模式：无 preloadJs 也预写登录头 Cookie（P2-4）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(sourceUrl: _sourceUrl, sourceName: '源A');
      await pumpScreen(tester, source: source, description: '<p>正文</p>');

      final manager = FakeWebViewPlatform.cookieManager!;
      expect(
        manager.setCookieCalls.map((c) => '${c.name}=${c.value}'),
        containsAll(<String>['sid=1', 'theme=dark']),
        reason: 'Cookie 预写不得依赖 preloadJs/overrideJs',
      );
      expect(manager.setCookieCalls.first.domain, 's.test');
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

  testWidgets('URL 模式：console 钩子先于桥注入；同文档重复 onPageStarted 去重', (tester) async {
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
        hasLength(1),
        reason: '同文档重复 onPageStarted 不得重复执行 preload/重置握手（P1-2）',
      );
      expect(
        controller.javaScriptCalls
            .where((js) => js.contains('__legadoConsoleHooked')),
        hasLength(1),
        reason: '同文档重复 onPageStarted 不得重复注入 console 钩子',
      );

      // 新文档导航：必须重新注入
      controller.emitPageStarted('https://s.test/next');
      await tester.pump();
      expect(
        controller.javaScriptCalls.where((js) => js.contains(_preloadMarker)),
        hasLength(2),
        reason: '新文档导航必须重新执行 preload',
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

  // ── 批21f P2-1：页面级看门狗接线 ─────────────────────────────────────────

  testWidgets('无 preloadJs：不臂看门狗（20s 内不重发 hello）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        singleUrl: true,
      );
      await pumpScreen(tester, source: source, description: null);
      final controller = FakeWebViewController.lastCreated!;

      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();

      expect(
        controller.javaScriptCalls.where(isWatchdogHello),
        isEmpty,
        reason: '未注入桥的文档不得臂看门狗/重发 hello',
      );
      expect(controller.javaScriptChannels, isEmpty);
    });
  });

  testWidgets('通道注册失败：不臂看门狗（20s 内不重发 hello）', (tester) async {
    await runWithWebView(() async {
      FakeWebViewPlatform.failNextJavaScriptChannelAdd = true;
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        singleUrl: true,
      );
      await pumpScreen(tester, source: source, description: null);
      final controller = FakeWebViewController.lastCreated!;
      expect(controller.javaScriptChannels, isEmpty, reason: '注册必须失败');

      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();

      expect(
        controller.javaScriptCalls.where(isWatchdogHello),
        isEmpty,
        reason: '通道未注册时页面无法回执，不得空转重发 hello',
      );
    });
  });

  testWidgets('preloadJs + 通道注册成功：4s 后确实重发 hello（P2-3 正例）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        singleUrl: true,
      );
      await pumpScreen(tester, source: source, description: null);
      final controller = FakeWebViewController.lastCreated!;
      expect(controller.javaScriptChannels, hasLength(1),
          reason: 'preloadJs 非空且通道注册成功');

      controller.emitPageStarted(_articleUrl);
      await tester.pump();

      // 看门狗 4s 未到：不得重发
      await tester.pump(const Duration(seconds: 3));
      expect(
        controller.javaScriptCalls.where(isWatchdogHello),
        isEmpty,
        reason: '4s 看门狗未到前不得重发 hello',
      );

      // 4s 超时：必须重发 hello（本代文档确实注入了桥）
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        controller.javaScriptCalls.where(isWatchdogHello),
        hasLength(1),
        reason: '通道注册成功且未握手时，看门狗必须重发 hello',
      );
    });
  });

  testWidgets('主框架错误：停止看门狗（不再空转重发 hello，P3-5）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        singleUrl: true,
      );
      await pumpScreen(tester, source: source, description: null);
      final controller = FakeWebViewController.lastCreated!;

      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(controller.javaScriptCalls.where(isWatchdogHello), isEmpty);

      // 主框架失败：文档已不可用，必须取消计时器
      controller.emitWebResourceError('net::ERR_FAILED');
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(
        controller.javaScriptCalls.where(isWatchdogHello),
        isEmpty,
        reason: '主框架错误后看门狗必须停止，不得每 4s 空转重发 hello',
      );
    });
  });

  testWidgets('主框架错误后同 URL 重试：必须重新注入 preload（P2-1）', (tester) async {
    await runWithWebView(() async {
      final source = RssSource(
        sourceUrl: _sourceUrl,
        sourceName: '源A',
        preloadJs: _preloadMarker,
        singleUrl: true,
      );
      await pumpScreen(tester, source: source, description: null);
      final controller = FakeWebViewController.lastCreated!;

      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      expect(
        controller.javaScriptCalls.where((js) => js.contains(_preloadMarker)),
        hasLength(1),
      );

      // 主框架加载失败（未走 onPageFinished）：清空去重键
      controller.emitWebResourceError('net::ERR_TIMED_OUT');
      await tester.pump();

      // 同 URL 重试：必须重新注入
      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      expect(
        controller.javaScriptCalls.where((js) => js.contains(_preloadMarker)),
        hasLength(2),
        reason: '主框架错误后的同 URL 重试不得被去重拦截',
      );

      // 子资源错误不影响去重键（同文档重复 onPageStarted 仍跳过）
      controller.emitWebResourceError('子资源 404', isForMainFrame: false);
      await tester.pump();
      controller.emitPageStarted(_articleUrl);
      await tester.pump();
      expect(
        controller.javaScriptCalls.where((js) => js.contains(_preloadMarker)),
        hasLength(2),
        reason: '子资源错误不得清空去重键',
      );
    });
  });
}
