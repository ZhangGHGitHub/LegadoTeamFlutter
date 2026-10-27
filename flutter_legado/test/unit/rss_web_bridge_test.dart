// RSS WebView preloadJs 宿主桥单元测试（批21b）
//
// 覆盖：`__prepare` 解析、协议编码、hello/nonce 握手、方法白名单转发、
// 30s（测试用短超时）失败回填、`__store` 写穿、动作分发、Cookie 辅助、
// 组合脚本注入顺序，以及**同步面纯函数/同步网络报错**的真实 JS 执行
// （Node 可用时执行 `kRssBridgeSyncShimBody`，不可用时降级为结构断言）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/services/rss_web_bridge.dart';
import 'package:flutter_legado/src/services/rss_web_config.dart';

import '../mocks/mocks.dart';

/// 组合一次 `__prepare` 成功信封
String _prepareEnvelope({
  String script = '(() => {\n  // 桥头\n',
  Object? snapshot = const <String, dynamic>{
    'sourceUrl': 'https://s.test/feed',
    'sourceName': '测试源',
    'userAgent': 'UA-Prepare',
    'loginHeader': '{"Cookie":"sid=1"}',
    'vars': <String, String>{'k': 'v'},
  },
}) =>
    jsonEncode(<String, dynamic>{
      'ok': true,
      'value': <String, dynamic>{'script': script, 'snapshot': snapshot},
      'error': null,
    });

/// 组合一次宿主调用成功信封
String _okEnvelope(Object? value) => jsonEncode(<String, dynamic>{
      'ok': true,
      'value': value,
      'error': null,
    });

String _errorEnvelope(String error) => jsonEncode(<String, dynamic>{
      'ok': false,
      'value': null,
      'error': error,
    });

/// 页面消息
String _pageMessage({
  required String method,
  String id = 'rss_1',
  String args = '[]',
  String? nonce,
}) =>
    jsonEncode(<String, dynamic>{
      'nonce': nonce,
      'id': id,
      'method': method,
      'args': args,
    });

void main() {
  late MockRustApi api;
  late List<String> runLog;
  late List<RssWebBridgeAction> actions;

  RssWebBridge newBridge({
    Duration timeout = const Duration(seconds: 30),
    Duration handshakeTimeout = const Duration(seconds: 10),
    List<String>? log,
  }) {
    return RssWebBridge(
      sourceUrl: 'https://s.test/feed',
      api: api,
      runJavaScript: (js) async => (log ?? runLog).add(js),
      requestTimeout: timeout,
      handshakeTimeout: handshakeTimeout,
      onAction: actions.add,
      onLog: (message) => (log ?? runLog).add('LOG:$message'),
      random: Random(7),
    );
  }

  /// 完成握手（返回 nonce）
  Future<String> handshake(RssWebBridge bridge) async {
    await bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
    final nonce = bridge.nonce;
    expect(nonce, isNotNull, reason: 'hello 后必须生成 nonce');
    return nonce!;
  }

  setUpAll(registerFallbacks);

  setUp(() {
    api = MockRustApi();
    runLog = <String>[];
    actions = <RssWebBridgeAction>[];
  });

  group('__prepare 解析', () {
    test('成功：透传 channelName/callbackName/ua 并解析 script/snapshot', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _prepareEnvelope());

      final bridge = newBridge();
      final result = await bridge.prepare(userAgent: 'UA-X');

      expect(result, isNotNull);
      expect(result!.script, contains('// 桥头'));
      expect(result.sourceUrl, 'https://s.test/feed');
      expect(result.sourceName, '测试源');
      expect(result.userAgent, 'UA-Prepare');
      expect(result.loginHeader, '{"Cookie":"sid=1"}');
      expect(result.vars, {'k': 'v'});

      final captured = verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__prepare',
          captureAny(),
        ),
      ).captured.single as String;
      final params = (jsonDecode(captured) as List).single as Map;
      expect(params['channelName'], bridge.channelName);
      expect(params['callbackName'], bridge.callbackName);
      expect(params['ua'], 'UA-X');
      expect(bridge.channelName, startsWith('__legado_rss_'));
      expect(bridge.nativeChannelName, startsWith('__legado_rssNative_'));
      expect(bridge.nativeChannelName, isNot(bridge.channelName),
          reason: '平台通道名与页面桥对象名必须分离，避免覆写平台注入对象');
    });

    test('失败信封 / 非法 JSON → null（降级无宿主绑定）', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _errorEnvelope('当前构建未启用 quickjs'));
      expect(await newBridge().prepare(), isNull);

      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => 'not-json');
      expect(await newBridge().prepare(), isNull);

      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenThrow(Exception('boom'));
      expect(await newBridge().prepare(), isNull);
    });
  });

  group('协议编码', () {
    test('回填结果脚本携带回调名/id/ok/payload 字面量', () {
      final script = rssBridgeReplyScript(
        callbackName: 'cb',
        id: 'id 1',
        ok: false,
        payload: '错误"信息',
      );
      expect(script, contains('window["cb"]("id 1", false, '));
      expect(script, contains(r'错误\"信息'));
    });

    test('U+2028/U+2029 转义避免旧引擎断句', () {
      final literal = rssJsLiteral('a\u2028b\u2029c');
      expect(literal, contains(r'\u2028'));
      expect(literal, contains(r'\u2029'));
    });

    test('nonce 回填脚本', () {
      final script = rssBridgeNonceScript(callbackName: 'cb', nonce: 'n1');
      expect(script, contains('window["cb_nonce"]("n1")'));
    });

    test('信封解析：actions 仅保留对象项', () {
      final envelope = RssWebBridgeEnvelope.parse(jsonEncode({
        'ok': true,
        'value': 1,
        'error': null,
        'actions': [
          {'action': 'toast', 'text': 'x'},
          'bad',
        ],
      }));
      expect(envelope.ok, isTrue);
      expect(envelope.value, 1);
      expect(envelope.actions, hasLength(1));
      expect(envelope.actions.single['action'], 'toast');
    });
  });

  group('hello/nonce 握手', () {
    test('首个 hello 接受并回填 nonce；后续消息必须携带 nonce', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope('v'));
      final bridge = newBridge();
      final nonce = await handshake(bridge);

      expect(bridge.isHandshaken, isTrue);
      expect(
        runLog.any((js) => js.contains('_nonce') && js.contains(nonce)),
        isTrue,
        reason: '必须经 runJavaScript 回填 nonce',
      );

      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://a"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);
      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          'getAwait',
          '["https://a"]',
        ),
      ).called(1);
    });

    test('页面导航后重置握手：新 hello 接受、旧 nonce 拒绝', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope('v'));
      final bridge = newBridge();
      final firstNonce = await handshake(bridge);

      bridge.beginNavigation();
      expect(bridge.isHandshaken, isFalse);
      expect(bridge.nonce, isNull);

      final secondNonce = await handshake(bridge);
      expect(secondNonce, isNot(firstNonce),
          reason: '新文档必须换发 nonce');

      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://old"]',
        nonce: firstNonce,
      ));
      await Future<void>.delayed(Duration.zero);
      verifyNever(
        () => api.rssWebViewHostCall(any(), 'getAwait', any()),
      );
    });

    test('重复 hello 拒绝（nonce 不变）', () async {
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
      expect(bridge.nonce, nonce);
      expect(
        runLog.any((js) => js.contains('重复 hello')),
        isTrue,
        reason: '重复 hello 必须回失败并留日志',
      );
    });

    test('错误 nonce / 握手前消息一律拒绝且不发起 RPC', () async {
      final bridge = newBridge();
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://a"]',
        nonce: null,
      ));
      verifyNever(
        () => api.rssWebViewHostCall(any(), any(), any()),
      );

      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://a"]',
        nonce: '${nonce}x',
      ));
      verifyNever(
        () => api.rssWebViewHostCall(
          any(),
          'getAwait',
          any(),
        ),
      );
      expect(
        runLog.any((js) => js.contains('nonce 校验失败')),
        isTrue,
      );
    });
  });

  group('白名单转发', () {
    test('白名单方法 → RPC → 回调 ok=true + value', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope('结果'));
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'ajaxAwait',
        id: 'id-9',
        args: '["https://a", "9000"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);

      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          'ajaxAwait',
          '["https://a", "9000"]',
        ),
      ).called(1);
      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('"id-9"'));
      expect(reply, contains('true'));
      expect(reply, contains('结果'));
    });

    test('失败信封 → 回调 ok=false + error', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _errorEnvelope('网络错误'));
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        id: 'id-10',
        args: '["https://a"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);

      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('"id-10"'));
      expect(reply, contains('false'));
      expect(reply, contains('网络错误'));
    });

    test('downloadFileAwait 在白名单内（由 Rust 返回明确不支持）', () {
      expect(kRssWebBridgeHostMethods, contains('downloadFileAwait'));
      expect(kRssWebBridgeHostMethods, contains('getStringAwait'));
    });

    test('未知方法 → 回调失败，且不发起 RPC', () async {
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'eval',
        id: 'id-x',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => api.rssWebViewHostCall(any(), any(), any()));
      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('未知宿主方法'));
    });

    test('超时（短超时）→ 回调 ok=false 超时文本，晚到结果忽略', () async {
      final completer = Completer<String>();
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) => completer.future);
      final bridge = newBridge(timeout: const Duration(milliseconds: 30));
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        id: 'id-slow',
        args: '["https://slow"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('"id-slow"'));
      expect(reply, contains('false'));
      expect(reply, contains('超时'));

      // 晚到结果不再回填
      final count = runLog.length;
      completer.complete(_okEnvelope('late'));
      await Future<void>.delayed(Duration.zero);
      expect(runLog.length, count, reason: '超时后晚到结果必须忽略');
    });

    test('__store 写穿：sourcePut/cachePut 等原样转发且不回填', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope(null));
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      final before = runLog.length;

      await bridge.handleMessage(_pageMessage(
        method: '__store',
        id: 'store_1',
        args: '{"op":"sourcePut","key":"token","value":"a-1"}',
        nonce: nonce,
      ));
      await bridge.handleMessage(_pageMessage(
        method: '__store',
        id: 'store_2',
        args: '{"op":"cachePut","key":"c","value":"v"}',
        nonce: nonce,
      ));
      // __store 串行保序：等待链上两次调用完成
      await Future<void>.delayed(const Duration(milliseconds: 5));

      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__store',
          '[{"op":"sourcePut","key":"token","value":"a-1"}]',
        ),
      ).called(1);
      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__store',
          '[{"op":"cachePut","key":"c","value":"v"}]',
        ),
      ).called(1);
      expect(
        runLog.length,
        before,
        reason: '__store 为写穿 fire-and-forget，不回填页面',
      );
    });

    test('__store toast 动作回传 Dart', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any())).thenAnswer(
        (_) async => jsonEncode({
          'ok': true,
          'value': null,
          'error': null,
          'actions': [
            {'action': 'toast', 'text': '保存成功', 'long': true},
          ],
        }),
      );
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: '__store',
        id: 'store_3',
        args: '{"op":"toast","value":"保存成功"}',
        nonce: nonce,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(actions, hasLength(1));
      expect(actions.single.name, 'toast');
      expect(actions.single.message, '保存成功');
      expect(actions.single.isLong, isTrue);
    });

    test('__action 动作分发（java.open）', () async {
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: '__action',
        id: 'act_1',
        args: '{"action":"open","name":"sort","url":"u","title":"t","origin":null}',
        nonce: nonce,
      ));
      expect(actions, hasLength(1));
      expect(actions.single.name, 'open');
      expect(actions.single.openName, 'sort');
      expect(actions.single.url, 'u');
    });
  });

  group('组合脚本', () {
    test('顺序：console 钩子 → 通道适配 → Rust 桥头 → 同步面 → preloadJs → 闭合', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _prepareEnvelope(script: 'RUST_HEAD_MARKER\n'));
      final bridge = newBridge();
      await bridge.prepare(userAgent: 'UA-1');
      final composed = bridge.composeInjection(
        'PRELOAD_JS_MARKER',
        includeConsoleHook: true,
      );

      final consoleIndex = composed.indexOf('__legadoConsoleHooked');
      final bootstrapIndex = composed.indexOf('__lgNative');
      final rustIndex = composed.indexOf('RUST_HEAD_MARKER');
      final shimIndex = composed.indexOf('var __lgB64Chars');
      final preloadIndex = composed.indexOf('PRELOAD_JS_MARKER');
      expect(consoleIndex, greaterThanOrEqualTo(0));
      expect(bootstrapIndex, greaterThan(consoleIndex));
      expect(rustIndex, greaterThan(bootstrapIndex));
      expect(shimIndex, greaterThan(rustIndex));
      expect(preloadIndex, greaterThan(shimIndex));
      expect(composed.trimRight(), endsWith('})();'));
    });

    test('未准备时返回裸 preloadJs（1:1 旧行为）', () {
      final bridge = newBridge();
      expect(bridge.composeInjection('PRELOAD'), 'PRELOAD');
    });

    test('HTML 内联转义 </script（大小写不敏感）', () {
      expect(
        rssEscapeScriptBody('var a = "</script>"; var b = "</SCRIPT>";'),
        'var a = "<\\/script>"; var b = "<\\/script>";',
      );
      expect(rssEscapeScriptBody('var a = 1;'), 'var a = 1;');
    });
  });

  group('shouldOverrideUrlLoading 快照桩', () {
    test('java.get/put/getKey/getTag/getVariable 同步可用', () {
      final script = rssBridgeOverrideScript(<String, dynamic>{
        'sourceUrl': 'https://s.override/feed',
        'sourceName': '快照源',
        'sourceVariable': 'sv',
        'userAgent': 'UA-O',
        'vars': <String, String>{'token': 't1'},
      });
      for (final needle in [
        'window.__legadoJava',
        'getKey',
        'getTag',
        'getVariable',
        'putVariable',
        'https://s.override/feed',
        '快照源',
      ]) {
        expect(script, contains(needle));
      }
      // 写入仅本地快照：不出现任何通道/存储调用
      expect(script, isNot(contains('postMessage')));
      expect(script, isNot(contains('__store')));
    });
  });

  group('Cookie 辅助', () {
    test('loginHeader 取 Cookie（大小写不敏感）', () {
      expect(
        rssBridgeCookieFromLoginHeader('{"cookie":"a=1; b=2"}'),
        'a=1; b=2',
      );
      expect(
        rssBridgeCookieFromLoginHeader('{"Cookie":"  c=3  "}'),
        'c=3',
      );
      expect(rssBridgeCookieFromLoginHeader('{"X":"1"}'), isNull);
      expect(rssBridgeCookieFromLoginHeader('not-json'), isNull);
      expect(rssBridgeCookieFromLoginHeader(null), isNull);
    });

    test('__cookieSet 透传 url/cookie', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope(null));
      final bridge = newBridge();
      await bridge.pushCookies(
        url: 'https://s.test/a',
        cookie: 'sid=1; t=2',
      );
      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__cookieSet',
          '[{"url":"https://s.test/a","cookie":"sid=1; t=2"}]',
        ),
      ).called(1);
    });
  });

  group('同步面（JS 真实执行）', () {
    final nodeAvailable = _nodeAvailable();

    test(
      '纯函数向量 + 同步网络报错（Node 实执行）',
      () async {
        final outputs = _runSyncShimInNode();
        final java = outputs['java'] as Map<String, dynamic>;
        final network = outputs['network'] as Map<String, dynamic>;
        final logActions = outputs['logActions'] as List<dynamic>;

        // base64（UTF-8）
        expect(java['base64EncodeHello'], 'aGVsbG8=');
        expect(java['base64EncodeCjk'], '6YeN55Sf');
        expect(java['base64DecodeCjk'], '重生');
        // md5
        expect(java['md5Empty'], 'd41d8cd98f00b204e9800998ecf8427e');
        expect(java['md5Hello'], '5d41402abc4b2a76b9719d911017c592');
        expect(java['md5Hex16'], 'bc4b2a76b9719d91');
        // hex
        expect(java['hexEncodeCjk'], 'e9878de7949f');
        expect(java['hexDecodeCjk'], '重生');
        // Java URLEncoder 语义（空格 -> +，保留 -._*，~ 编码）
        expect(java['encodeUriCjk'], '%E9%87%8D%E7%94%9F');
        expect(java['encodeUriReserved'], 'a+b%26c%7E*');
        // UA / 单参 get 回落
        expect(java['userAgent'], 'UA-Sync');
        expect(java['sourceGet'], 'V:token');
        // 同步网络全部明确抛错并 log
        for (final name in [
          'ajax',
          'connect',
          'post',
          'head',
          'webView',
          'webViewGetSource',
          'get',
        ]) {
          expect(
            network[name],
            contains('同步网络在当前平台不可用'),
            reason: 'java.$name 必须抛平台不可用错误',
          );
        }
        expect(logActions, isNotEmpty);
        expect(
          logActions.any(
            (item) =>
                item is Map &&
                item['action'] == 'log' &&
                item['message'].toString().contains('java.ajax'),
          ),
          isTrue,
        );
      },
      skip: nodeAvailable ? false : '未找到 node，跳过 JS 实执行（结构断言仍生效）',
    );

    test('同步面脚本不使用通道/RPC（纯函数摊平）', () {
      final script = rssBridgeSyncShimScript(
        bridgeObjectName: '__legado_rssBridge_x',
        userAgent: 'UA',
      );
      for (final name in [
        'base64Encode',
        'base64Decode',
        'md5Encode',
        'md5Encode16',
        'hexEncodeToString',
        'hexDecodeToString',
        'encodeURI',
        'getWebViewUA',
        'open',
        'searchBook',
        'addBook',
        'showPhoto',
        'openUrl',
      ]) {
        expect(script, contains(name), reason: '同步面缺少 $name');
      }
      // 纯函数绑定段不发起 RPC（动作段才使用通道）
      final pureSection = kRssBridgeSyncShimBody.substring(
        0,
        kRssBridgeSyncShimBody.indexOf('// ── 动作摊平'),
      );
      expect(pureSection, isNot(contains('.request(')));
      expect(pureSection, isNot(contains('postMessage')));
    });
  });
}

// ─── Node 执行辅助（仅开发/CI 环境有 node 时启用） ───────────────────────────

bool _nodeAvailable() {
  try {
    final result = Process.runSync('node', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 在 Node 中执行 `kRssBridgeSyncShimBody`，返回结构化结果
Map<String, dynamic> _runSyncShimInNode() {
  final harness = r'''
var __lgActions = [];
var __lgJava = {
  get: function (key) { return 'V:' + String(key); }
};
var __lgAction = function (payload) { __lgActions.push(payload); };
var __lgUserAgent = 'UA-Sync';
''' +
      kRssBridgeSyncShimBody +
      r'''
var network = {};
var calls = [
  ['ajax', function () { return __lgJava.ajax('https://x'); }],
  ['connect', function () { return __lgJava.connect('https://x'); }],
  ['post', function () { return __lgJava.post('https://x', 'b'); }],
  ['head', function () { return __lgJava.head('https://x'); }],
  ['webView', function () { return __lgJava.webView('h'); }],
  ['webViewGetSource', function () { return __lgJava.webViewGetSource('h'); }],
  ['get', function () { return __lgJava.get('https://x', '{}'); }]
];
for (var i = 0; i < calls.length; i++) {
  try {
    calls[i][1]();
    network[calls[i][0]] = 'no-throw';
  } catch (e) {
    network[calls[i][0]] = String(e && e.message ? e.message : e);
  }
}
process.stdout.write(JSON.stringify({
  java: {
    base64EncodeHello: __lgJava.base64Encode('hello'),
    base64EncodeCjk: __lgJava.base64Encode('重生'),
    base64DecodeCjk: __lgJava.base64Decode('6YeN55Sf'),
    md5Empty: __lgJava.md5Encode(''),
    md5Hello: __lgJava.md5Encode('hello'),
    md5Hex16: __lgJava.md5Encode16('hello'),
    hexEncodeCjk: __lgJava.hexEncodeToString('重生'),
    hexDecodeCjk: __lgJava.hexDecodeToString('e9878de7949f'),
    encodeUriCjk: __lgJava.encodeURI('重生'),
    encodeUriReserved: __lgJava.encodeURI('a b&c~*'),
    userAgent: __lgJava.getWebViewUA(),
    sourceGet: __lgJava.get('token')
  },
  network: network,
  logActions: __lgActions
}));
''';

  final dir = Directory.systemTemp.createTempSync('rss_bridge_js_');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}sync_shim.js')
      ..writeAsStringSync(harness);
    // Node 在中文 Windows 下默认系统编码为 GBK；显式按 UTF-8 解码，
    // 避免 CJK 向量被误判（CI 为 UTF-8 环境，同样安全）
    final result = Process.runSync(
      'node',
      [file.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'Node 执行同步面失败：${result.stderr}',
    );
    final decoded = jsonDecode(result.stdout as String);
    expect(decoded, isA<Map>());
    return Map<String, dynamic>.from(decoded as Map);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响用例
    }
  }
}
